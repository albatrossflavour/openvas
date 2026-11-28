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

    def __init__(self, config=True, tasks="", schedules="", fail=None, targets=""):
        self.config = config
        self.tasks = tasks
        self.targets = targets
        self.schedules = schedules
        self.fail = fail
        self.writes = []

    def send_command(self, xml):
        verb = re.match(r"<(\w+)", xml).group(1)
        if self.fail and verb == self.fail:
            return '<r status="500" status_text="broken"/>'
        reads = {
            "get_tasks": self.tasks,
            "get_targets": self.targets,
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


def converged(tmp_path):
    """A state file and a gvmd that already matches it."""
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
    return path, gvmd


def test_schedule_off_is_stable_once_cleared(tmp_path):
    code, out = run("check", *converged(tmp_path))
    assert code == 0, out


def test_plan_says_when_there_is_nothing_to_do(tmp_path):
    code, out = run("plan", *converged(tmp_path))
    assert code == 0
    assert out.strip() == "nothing to do"


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


# New hosts: a certname no managed task's current target lists gets a one-off.

def new_host_state(tmp_path, members, enabled=True):
    path = state(tmp_path, hosts=sorted(set(members.values())))
    doc = json.loads(open(path).read())
    doc["new_host_scan"] = enabled
    doc["targets"][0]["members"] = members
    doc["tasks"][0]["observers"] = ["soundwave"]
    open(path, "w").write(json.dumps(doc))
    return path


def settled(tmp_path, members, one_off=None):
    """A gvmd that an apply of members has converged, optionally with a one-off task already there.

    one_off is (certnames, its last report's scan_end, the family task's last report's scan_end).
    """
    first = FakeGvmd()
    run("apply", new_host_state(tmp_path, members), first)
    create = next(w for w in first.writes if w.startswith("<create_target"))
    name = re.search(r"<name>(.*?)</name>", create).group(1)
    comment = re.search(r"<comment>(.*?)</comment>", create).group(1)
    task_comment = re.search(r"<comment>(.*?)</comment>", next(w for w in first.writes if w.startswith("<create_task"))).group(1)
    prefs = ('<preferences><preference><scanner_name>max_checks</scanner_name><value>4</value></preference>'
             '<preference><scanner_name>max_hosts</scanner_name><value>20</value></preference></preferences>')
    family_end = one_off[2] if one_off else ""
    report = f'<last_report><report id="r1"><scan_end>{family_end}</scan_end></report></last_report>' if family_end else ""
    tasks = (f'<task id="t1"><name>Puppet: Debian</name><comment>{task_comment}</comment><status>Done</status>'
             f'<target id="x1"/><schedule id="sch1"/><observers>soundwave</observers>{prefs}{report}</task>')
    targets = f'<target id="x1"><name>{name}</name><comment>{comment}</comment></target>'
    if one_off:
        certnames, end, _ = one_off
        tasks += (f'<task id="t2"><name>Puppet: Debian new hosts</name><comment>{MARKER} sha256=x</comment>'
                  f'<status>Done</status><target id="x2"/><modification_time>2026-11-01T00:00:00Z</modification_time>'
                  f'<last_report><report id="r2"><scan_end>{end}</scan_end></report></last_report></task>')
        targets += (f'<target id="x2"><name>Puppet: Debian new hosts [abcd1234]</name>'
                    f'<comment>{MARKER} sha256=y certnames={",".join(certnames)}</comment></target>')
    sched = f'<schedule id="sch1"><name>Puppet: weekly Debian</name><comment>{MARKER} sha256=old</comment></schedule>'
    gvmd = FakeGvmd(tasks=tasks, targets=targets, schedules=sched)
    # The schedule's digest is whatever the first apply stamped.
    sched_comment = re.search(r"<comment>(.*?)</comment>", next(w for w in first.writes if w.startswith("<create_schedule"))).group(1)
    gvmd.schedules = sched.replace(f"{MARKER} sha256=old", sched_comment)
    return gvmd


def verbs(gvmd):
    return [re.match(r"<(\w+)", w).group(1) for w in gvmd.writes]


def test_targets_list_their_certnames(tmp_path):
    gvmd = FakeGvmd()
    run("apply", new_host_state(tmp_path, {"b.example.com": "192.0.2.2", "a.example.com": "192.0.2.1"}), gvmd)
    create = next(w for w in gvmd.writes if w.startswith("<create_target"))
    assert "certnames=a.example.com,b.example.com</comment>" in create


def test_a_first_install_scans_nothing_extra(tmp_path):
    gvmd = FakeGvmd()
    run("apply", new_host_state(tmp_path, {"a.example.com": "192.0.2.1"}), gvmd)
    assert "start_task" not in verbs(gvmd)
    assert len([v for v in verbs(gvmd) if v == "create_task"]) == 1


def test_a_converged_gvmd_with_no_new_hosts_does_nothing(tmp_path):
    gvmd = settled(tmp_path, {"a.example.com": "192.0.2.1"})
    code, out = run("check", new_host_state(tmp_path, {"a.example.com": "192.0.2.1"}), gvmd)
    assert code == 0, out


def test_a_new_certname_gets_a_one_off_scan_of_only_itself(tmp_path):
    gvmd = settled(tmp_path, {"a.example.com": "192.0.2.1"})
    path = new_host_state(tmp_path, {"a.example.com": "192.0.2.1", "b.example.com": "192.0.2.2"})
    assert run("check", path, gvmd)[0] == 3

    code, out = run("apply", path, gvmd)
    assert code == 0, out
    targets = [w for w in gvmd.writes if w.startswith("<create_target")]
    one_off = next(w for w in targets if "Puppet: Debian new hosts [" in w)
    assert "<hosts>192.0.2.2</hosts>" in one_off
    assert "certnames=b.example.com</comment>" in one_off
    task = next(w for w in gvmd.writes if w.startswith("<create_task"))
    assert "<name>Puppet: Debian new hosts</name>" in task
    assert "<schedule" not in task
    assert "<observers>soundwave</observers>" in task
    assert verbs(gvmd)[-1] == "start_task"
    assert "start task Puppet: Debian new hosts (b.example.com)" in out


def test_new_host_scan_off_scans_nothing_extra(tmp_path):
    gvmd = settled(tmp_path, {"a.example.com": "192.0.2.1"})
    run("apply", new_host_state(tmp_path, {"a.example.com": "192.0.2.1", "b.example.com": "192.0.2.2"}, enabled=False), gvmd)
    assert "start_task" not in verbs(gvmd)
    assert not [w for w in gvmd.writes if "new hosts" in w]


def test_an_address_change_is_not_a_new_host(tmp_path):
    gvmd = settled(tmp_path, {"a.example.com": "192.0.2.1"})
    run("apply", new_host_state(tmp_path, {"a.example.com": "192.0.2.77"}), gvmd)
    assert "create_target" in verbs(gvmd)
    assert "start_task" not in verbs(gvmd)


def test_a_target_from_before_certnames_were_listed_scans_nothing_extra(tmp_path):
    gvmd = settled(tmp_path, {"a.example.com": "192.0.2.1"})
    gvmd.targets = re.sub(r" certnames=[^<]*", "", gvmd.targets)
    run("apply", new_host_state(tmp_path, {"a.example.com": "192.0.2.1", "b.example.com": "192.0.2.2"}), gvmd)
    assert "start_task" not in verbs(gvmd)


def test_a_standing_one_off_is_kept_until_the_weekly_report_is_newer(tmp_path):
    members = {"a.example.com": "192.0.2.1", "b.example.com": "192.0.2.2"}
    gvmd = settled(tmp_path, members, one_off=(["b.example.com"], "2026-11-26T10:00:00Z", "2026-11-22T10:00:00Z"))
    code, out = run("check", new_host_state(tmp_path, members), gvmd)
    assert code == 0, out


def test_a_superseded_one_off_goes_with_its_target(tmp_path):
    members = {"a.example.com": "192.0.2.1", "b.example.com": "192.0.2.2"}
    gvmd = settled(tmp_path, members, one_off=(["b.example.com"], "2026-11-26T10:00:00Z", "2026-11-29T10:00:00Z"))
    code, out = run("apply", new_host_state(tmp_path, members), gvmd)
    assert code == 0, out
    assert '<delete_task task_id="t2" ultimate="1"/>' in gvmd.writes
    assert '<delete_target target_id="x2" ultimate="1"/>' in gvmd.writes
    assert verbs(gvmd).index("delete_task") < verbs(gvmd).index("delete_target")


def test_more_new_hosts_join_a_standing_one_off_and_it_runs_again(tmp_path):
    members = {"a.example.com": "192.0.2.1", "b.example.com": "192.0.2.2"}
    gvmd = settled(tmp_path, members, one_off=(["b.example.com"], "2026-11-26T10:00:00Z", "2026-11-22T10:00:00Z"))
    run("apply", new_host_state(tmp_path, dict(members, **{"c.example.com": "192.0.2.3"})), gvmd)
    one_off = next(w for w in gvmd.writes if w.startswith("<create_target") and "new hosts" in w)
    assert "<hosts>192.0.2.2,192.0.2.3</hosts>" in one_off
    assert any(w.startswith('<modify_task task_id="t2"') for w in gvmd.writes)
    assert '<start_task task_id="t2"/>' in gvmd.writes
    assert '<delete_target target_id="x2" ultimate="1"/>' in gvmd.writes


def test_a_one_off_is_not_started_while_a_scan_runs(tmp_path):
    gvmd = settled(tmp_path, {"a.example.com": "192.0.2.1"})
    gvmd.tasks = gvmd.tasks.replace("<status>Done</status>", "<status>Running</status>")
    code, out = run("apply", new_host_state(tmp_path, {"a.example.com": "192.0.2.1", "b.example.com": "192.0.2.2"}), gvmd)
    assert code == 0
    assert "deferred" in out
    assert gvmd.writes == []
