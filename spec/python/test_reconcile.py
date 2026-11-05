"""reconcile.gmp.py against a fake gvmd. gvm-script supplies `gmp` and `args`."""
import io
import json
import os
import re
import runpy
import contextlib
from types import SimpleNamespace

import pytest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "..", "files", "reconcile.gmp.py")
MARKER = "managed-by=puppet"


class FakeGvmd:
    """Answers GMP from canned lists and records every write."""

    def __init__(self, config=True, tasks="", schedules="", fail=None):
        self.config = config
        self.tasks = tasks
        self.schedules = schedules
        self.fail = fail
        self.writes = []

    def send_command(self, xml):
        verb = re.match(r"<(\w+)", xml).group(1)
        if self.fail and verb == self.fail:
            return '<r status="500" status_text="broken"/>'
        reads = {
            "get_tasks": self.tasks,
            "get_schedules": self.schedules,
            "get_scanners": '<scanner id="s1"><name>OpenVAS Default</name></scanner>',
            "get_configs": '<config id="c1"><name>Full and fast</name></config>' if self.config else "",
            "get_port_lists": '<port_list id="p1"><name>All IANA assigned TCP</name></port_list>',
            "get_roles": '<role id="r1"><name>Observer</name></role>',
        }
        if verb.startswith("get_"):
            return f'<r status="200">{reads.get(verb, "")}</r>'
        self.writes.append(xml)
        return '<r status="201" id="new-id"/>'


def state(tmp_path, schedule="Puppet: weekly Debian", hosts=("192.0.2.1",)):
    doc = {
        "marker": MARKER,
        "purge": False,
        "scanner": "OpenVAS Default",
        "scan_config": "Full and fast",
        "port_list": "All IANA assigned TCP",
        "credentials": [],
        "users": [],
        "schedules": [{"name": schedule, "timezone": "UTC", "icalendar": "X"}] if schedule else [],
        "targets": [{"name": "Puppet: Debian", "hosts": list(hosts), "alive_test": "Consider Alive",
                     "ssh_credential": None, "smb_credential": None, "ssh_port": 22}] if hosts else [],
        "tasks": [{"name": "Puppet: Debian", "target": "Puppet: Debian", "schedule": schedule,
                   "max_hosts": 20, "max_checks": 4, "observers": []}] if hosts else [],
    }
    path = tmp_path / "state.json"
    path.write_text(json.dumps(doc))
    return str(path)


def run(mode, path, gvmd):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), pytest.raises(SystemExit) as exc:
        runpy.run_path(SCRIPT, init_globals={"gmp": gvmd, "args": SimpleNamespace(argv=["reconcile.gmp.py", mode, path])})
    return exc.value.code, out.getvalue()


@pytest.mark.parametrize("mode", ["check", "apply"])
def test_feed_not_ready_defers(tmp_path, mode):
    gvmd = FakeGvmd(config=False)
    code, out = run(mode, state(tmp_path), gvmd)
    assert code == 0
    assert "deferred" in out
    assert gvmd.writes == []


def test_feed_not_ready_is_reported_by_plan(tmp_path):
    code, out = run("plan", state(tmp_path), FakeGvmd(config=False))
    assert code == 0
    assert "deferred" in out


def test_real_gvmd_error_fails(tmp_path):
    code, out = run("check", state(tmp_path), FakeGvmd(fail="get_tasks"))
    assert code == 1
    assert "deferred" not in out


def test_no_hosts_refuses(tmp_path):
    gvmd = FakeGvmd()
    code, out = run("apply", state(tmp_path, hosts=()), gvmd)
    assert code == 2
    assert "refusing" in out
    assert gvmd.writes == []


def test_a_single_host_is_enough(tmp_path):
    code, _ = run("apply", state(tmp_path, hosts=("192.0.2.1",)), FakeGvmd())
    assert code == 0


def test_schedule_absent_on_create(tmp_path):
    gvmd = FakeGvmd()
    code, _ = run("apply", state(tmp_path, schedule=None), gvmd)
    assert code == 0
    creates = [w for w in gvmd.writes if w.startswith("<create_task")]
    assert len(creates) == 1
    assert "<schedule" not in creates[0]
    assert not [w for w in gvmd.writes if w.startswith("<create_schedule")]


def existing(schedule):
    task = (f'<task id="t1"><name>Puppet: Debian</name><comment>{MARKER} sha256=old</comment>'
            f'<status>Done</status><target id="x"/>{schedule}</task>')
    sched = f'<schedule id="sch1"><name>Puppet: weekly Debian</name><comment>{MARKER} sha256=old</comment></schedule>'
    return FakeGvmd(tasks=task, schedules=sched)


def test_schedule_off_clears_then_deletes(tmp_path):
    gvmd = existing('<schedule id="sch1"/>')
    code, _ = run("apply", state(tmp_path, schedule=None), gvmd)
    assert code == 0
    verbs = [re.match(r"<(\w+)", w).group(1) for w in gvmd.writes]
    assert verbs.index("modify_task") < verbs.index("delete_schedule")
    modify = next(w for w in gvmd.writes if w.startswith("<modify_task"))
    assert '<schedule id="0"/>' in modify


def test_schedule_off_is_stable_once_cleared(tmp_path):
    task = FakeGvmd()
    path = state(tmp_path, schedule=None)
    run("apply", path, task)
    create = next(w for w in task.writes if w.startswith("<create_target"))
    name = re.search(r"<name>(.*?)</name>", create).group(1)
    comment = re.search(r"<comment>(.*?)</comment>", create).group(1)
    task_comment = re.search(r"<comment>(.*?)</comment>", next(w for w in task.writes if w.startswith("<create_task"))).group(1)
    gvmd = FakeGvmd(tasks=f'<task id="t1"><name>Puppet: Debian</name><comment>{task_comment}</comment><status>Done</status>'
                          f'<target id="x1"/><schedule id=""/>'
                          '<preferences><preference><scanner_name>max_checks</scanner_name><value>4</value></preference>'
                          '<preference><scanner_name>max_hosts</scanner_name><value>20</value></preference></preferences></task>')
    original = gvmd.send_command

    def with_target(xml):
        if xml.startswith("<get_targets"):
            return f'<r status="200"><target id="x1"><name>{name}</name><comment>{comment}</comment></target></r>'
        return original(xml)

    gvmd.send_command = with_target
    code, out = run("check", path, gvmd)
    assert code == 0, out


def test_schedule_removed_by_hand_is_repointed_in_one_run(tmp_path):
    path = state(tmp_path)
    first = FakeGvmd()
    run("apply", path, first)
    comment = re.search(r"<comment>(.*?)</comment>", next(w for w in first.writes if w.startswith("<create_task"))).group(1)
    create = next(w for w in first.writes if w.startswith("<create_target"))
    name = re.search(r"<name>(.*?)</name>", create).group(1)
    target_comment = re.search(r"<comment>(.*?)</comment>", create).group(1)
    gvmd = FakeGvmd(tasks=f'<task id="t1"><name>Puppet: Debian</name><comment>{comment}</comment><status>Done</status>'
                          f'<target id="x1"/><schedule id=""/>'
                          '<preferences><preference><scanner_name>max_checks</scanner_name><value>4</value></preference>'
                          '<preference><scanner_name>max_hosts</scanner_name><value>20</value></preference></preferences></task>')
    original = gvmd.send_command

    def with_target(xml):
        if xml.startswith("<get_targets"):
            return f'<r status="200"><target id="x1"><name>{name}</name><comment>{target_comment}</comment></target></r>'
        return original(xml)

    gvmd.send_command = with_target
    code, _ = run("apply", path, gvmd)
    assert code == 0
    verbs = [re.match(r"<(\w+)", w).group(1) for w in gvmd.writes]
    assert verbs.index("create_schedule") < verbs.index("modify_task")
    assert '<schedule id="new-id"/>' in next(w for w in gvmd.writes if w.startswith("<modify_task"))


def test_idle_needs_no_state_file(tmp_path):
    code, out = run("idle", str(tmp_path / "missing.json"), FakeGvmd())
    assert code == 0
    assert out.strip() == "idle"


def test_idle_reports_a_running_scan(tmp_path):
    gvmd = FakeGvmd(tasks="<task id='t'><name>a</name><status>Running</status></task>")
    code, _ = run("idle", str(tmp_path / "missing.json"), gvmd)
    assert code == 3
