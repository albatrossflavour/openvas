"""The rendered greenbone-reconcile wrapper, with a stub docker on PATH."""
import os
import re
import stat
import subprocess

import pytest

TEMPLATE = os.path.join(os.path.dirname(__file__), "..", "..", "templates", "greenbone-reconcile.epp")

STUB = """#!/bin/bash
printf '%s\\0' "$@" >> "$STUB_LOG"
printf '\\n' >> "$STUB_LOG"
case "$*" in
  *gvm-cli*) exit "${STUB_AUTH_RC:-0}" ;;
  *--new-password=*)
    count=$(cat "$STUB_LOG.resets" 2>/dev/null || echo 0)
    echo $((count + 1)) > "$STUB_LOG.resets"
    [ "$count" -lt "${STUB_RESET_FAILS:-0}" ] && exit 1
    exit "${STUB_RESET_RC:-0}"
    ;;
  *gvm-script*) echo "script ran"; exit "${STUB_SCRIPT_RC:-0}" ;;
esac
"""


@pytest.fixture
def box(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    docker = bin_dir / "docker"
    docker.write_text(STUB)
    docker.chmod(docker.stat().st_mode | stat.S_IEXEC)
    sleeper = bin_dir / "sleep"
    sleeper.write_text("#!/bin/sh\nexit 0\n")
    sleeper.chmod(0o755)
    paths = {"compose_file": tmp_path / "compose.yaml", "gmp_config": tmp_path / "gvm-admin.conf",
             "state_file": tmp_path / "scan-state.json", "script": tmp_path / "reconcile.gmp.py",
             "ready_marker": tmp_path / ".gvmd-ready"}
    source = open(TEMPLATE).read()
    body = re.sub(r"\A<%-.*?-%>\n", "", source, flags=re.S)
    body = re.sub(r"<%= \$(\w+) %>", lambda m: str(paths[m.group(1)]), body)
    wrapper = tmp_path / "greenbone-reconcile"
    wrapper.write_text(body)
    wrapper.chmod(0o750)
    paths["gmp_config"].write_text("[gmp]\nusername = admin\npassword = secret\n")
    paths["state_file"].write_text("{}")
    paths["compose_file"].write_text("name: x\n")

    def run(mode, **env):
        log = tmp_path / "log"
        log.write_text("")
        (tmp_path / "log.resets").unlink(missing_ok=True)
        result = subprocess.run([str(wrapper), mode], capture_output=True, text=True,
                                env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "STUB_LOG": str(log),
                                     **{k: str(v) for k, v in env.items()}})
        result.calls = log.read_text()
        return result

    run.paths = paths
    return run


@pytest.mark.parametrize("written,expected", [
    ("a%%b", "a%b"),
    ("a'b c", "a'b c"),
    ('$x"y', '$x"y'),
    ("back\\slash", "back\\slash"),
    ("50%%%%off", "50%%off"),
])
def test_set_password_passes_it_unchanged(box, written, expected):
    box.paths["gmp_config"].write_text(f"[gmp]\nusername = admin\npassword = {written}\n")
    result = box("set-password")
    assert result.returncode == 0, result.stderr
    assert f"--new-password={expected}\0" in result.calls


@pytest.mark.parametrize("mode", ["check", "apply", "set-password"])
def test_waits_quietly_before_first_login(box, mode):
    result = box(mode, STUB_AUTH_RC=1, STUB_RESET_RC=1)
    assert result.returncode == 0
    assert "waiting" in result.stdout
    assert "gvm-script" not in result.calls


@pytest.mark.parametrize("mode", ["check", "apply"])
def test_fails_after_first_login_when_gvmd_breaks(box, mode):
    box.paths["ready_marker"].write_text("")
    result = box(mode, STUB_SCRIPT_RC=1)
    assert result.returncode == 1


def test_set_password_fails_after_first_login(box):
    box.paths["ready_marker"].write_text("")
    assert box("set-password", STUB_RESET_RC=1).returncode != 0


def test_first_reset_retries_until_gvmd_accepts_it(box):
    result = box("set-password", STUB_RESET_FAILS=3)
    assert result.returncode == 0
    assert result.calls.count("--new-password=") == 4
    assert box.paths["ready_marker"].exists()


def test_first_reset_says_when_it_is_waiting(box):
    result = box("set-password", STUB_RESET_RC=1)
    assert "waiting" in result.stdout


def test_reset_that_does_not_log_in_keeps_waiting(box):
    result = box("set-password", STUB_AUTH_RC=1)
    assert result.returncode == 0
    assert "waiting" in result.stdout
    assert not box.paths["ready_marker"].exists()


@pytest.mark.parametrize("env", [{"STUB_RESET_RC": 1}, {"STUB_AUTH_RC": 1}])
def test_gives_up_waiting_after_a_day(box, env):
    old = 25 * 3600
    now = os.path.getmtime(box.paths["compose_file"])
    os.utime(box.paths["compose_file"], (now - old, now - old))
    assert box("set-password", **env).returncode != 0


def test_set_password_does_not_retry_after_first_login(box):
    box.paths["ready_marker"].write_text("")
    result = box("set-password", STUB_RESET_RC=1)
    assert result.calls.count("--new-password=") == 1


def test_auth_success_records_first_login(box):
    assert box("auth").returncode == 0
    assert box.paths["ready_marker"].exists()


def test_auth_failure_records_nothing(box):
    assert box("auth", STUB_AUTH_RC=1).returncode == 1
    assert not box.paths["ready_marker"].exists()


def test_check_passes_through_work_to_do(box):
    box.paths["ready_marker"].write_text("")
    assert box("check", STUB_SCRIPT_RC=3).returncode == 3


def test_check_records_first_login_then_runs(box):
    result = box("check")
    assert box.paths["ready_marker"].exists()
    assert "script ran" in result.stdout


def test_idle_mounts_no_state_file(box):
    box.paths["ready_marker"].write_text("")
    result = box("idle")
    assert result.returncode == 0
    assert "scan-state.json:/run" not in result.calls


def test_idle_skips_only_when_a_scan_runs(box):
    assert box("idle", STUB_SCRIPT_RC=3).returncode == 1
    assert box("idle", STUB_SCRIPT_RC=1).returncode == 0


@pytest.mark.parametrize("mode", ["idle", "check", "plan", "auth", "apply", "set-password"])
def test_missing_config_never_reaches_docker(box, mode):
    # Docker would create a missing bind source as a directory, which then
    # blocks the real file from ever being written.
    box.paths["gmp_config"].unlink()
    box("%s" % mode)
    assert box.paths["gmp_config"].exists() is False
    assert "-v" not in box(mode).calls.split("\0")


@pytest.mark.parametrize("mode", ["check", "apply", "plan"])
def test_missing_state_file_changes_nothing(box, mode):
    box.paths["state_file"].unlink()
    result = box(mode)
    assert result.returncode == 0
    assert "gvm-script" not in result.calls


def test_rejects_unknown_mode(box):
    assert box("nonsense").returncode == 64
