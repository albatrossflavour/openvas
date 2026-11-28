# Managed by Puppet (openvas) - do not edit by hand.
#
# Converge gvmd to the desired state Puppet renders: scan credentials, one
# target and one task per OS family, weekly schedules when enabled, an optional
# read-only user, and (with purge on) nothing else.
#
# Run by gvm-script, which supplies an authenticated `gmp` and `args`:
#   gvm-script ... reconcile.gmp.py check|apply|plan|idle /path/to/state.json
#
# check exits 0 when gvmd already matches (or a scan is running, or the feed is
# not imported yet, see below) and 3 when apply has work to do; apply exits 0 on
# success and 1 on failure; both exit 2 when the state holds no hosts.
# idle exits 0 when no scan is running and 3 when one is, and reads nothing
# from the state file; the stack's update timers use it to stay out of a scan.
# plan prints what apply would do even while a scan runs, changes nothing,
# and always exits 0. It's for a human, not for Puppet.
#
# Ownership: every object this creates carries a comment starting with the
# state's marker, followed by a digest of its definition. The digest is how a
# change is noticed without reading secrets back, which gvmd won't return.
#
# gvmd rules this works around:
# - A target's hosts and port list can't change while any task references it
#   ("Target is in use"), so a changed target is created under a new name and
#   the task is repointed, then the old one deleted.
# - <hosts> needs an <exclude_hosts> sibling.
# - Deletes without ultimate="1" go to the trashcan, and trashed tasks keep
#   their targets undeletable, so the trash is emptied before targets go.
# - A task that has reports only accepts a new target if it was created
#   alterable, so managed tasks are.
# - An Observer-role user sees a task, and that task's reports, only when named
#   in the task's observers, and sees no credentials, targets or other tasks.
#
# New hosts: with new_host_scan on, a certname in a target that no managed
# task's current target listed gets a one-off scan, so a node built midweek
# isn't left unscanned until its family's weekly run. Targets list their
# certnames in their comment, which is the record of what the last apply
# scanned. The one-off is a target and task of its own per group, named
# "<group> new hosts", with the group's credentials and observers and no
# schedule, started once apply has made every other change. Anything reading
# each task's last report sees it beside the weekly ones. It is deleted, with
# its report, once the group's own task has a report newer than it, because
# by then that report covers its hosts and the older one would only repeat
# stale findings. More new hosts before then join it and it runs again. A
# target written before certnames were listed counts as knowing every host,
# so upgrading scans nothing, and so does a first install with no managed
# tasks at all.
#
# Nothing is touched while any task is running or queued: repointing a running
# task is untested, and a purge would delete the task mid-scan. Nothing is
# touched before the feed import has delivered the scan config, port list, and
# roles either, which on a new install takes a long time.

import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

NEW_HOSTS = " new hosts"
BUSY = {"Requested", "Queued", "Running", "Stop Requested", "Delete Requested", "Processing"}


def call(xml):
    root = ET.fromstring(gmp.send_command(xml))  # noqa: F821 - provided by gvm-script
    status = root.get("status", "")
    if not status.startswith("2"):
        raise RuntimeError(f"{xml.split()[0]}: {status} {root.get('status_text')}")
    return root


def digest(obj):
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()[:16]


def by_id(root, tag):
    return {e.get("id"): e for e in root.findall(tag)}


def text(e, path, default=""):
    v = e.findtext(path)
    return default if v is None else v


class FeedNotReady(Exception):
    pass


def builtin_id(tag, name, xml):
    for e in call(xml).findall(tag):
        if text(e, "name") == name:
            return e.get("id")
    raise FeedNotReady(f"no {tag} named {name!r}")


def listed(target):
    """The certnames a target's comment lists, or None for a target that lists none."""
    if target is None:
        return None
    for word in text(target, "comment").split():
        if word.startswith("certnames="):
            return set(filter(None, word[len("certnames="):].split(",")))
    return None


def target_of(task):
    t = task.find("target")
    return t.get("id") if t is not None else ""


def last_end(task):
    return task.findtext("last_report/report/scan_end") or ""


def main(mode, state_path):
    if mode == "idle":
        tasks = call('<get_tasks filter="rows=-1" details="0"/>').findall("task")
        busy = [text(t, "name") for t in tasks if text(t, "status") in BUSY]
        print(f"busy: {', '.join(busy)}" if busy else "idle")
        return 3 if busy else 0

    with open(state_path) as fh:
        state = json.load(fh)
    marker = state["marker"]
    purge = bool(state.get("purge", False))

    if not any(t["hosts"] for t in state["targets"]):
        print("refusing: desired state has no hosts")
        return 2

    def managed(e):
        return text(e, "comment").startswith(marker)

    def stamp(d):
        return f"{marker} sha256={d}"

    tasks = by_id(call('<get_tasks filter="rows=-1" details="1"/>'), "task")
    busy = [text(t, "name") for t in tasks.values() if text(t, "status") in BUSY]
    if busy and mode != "plan":
        print(f"deferred: scan in progress ({', '.join(busy)}); nothing changed")
        return 0
    if busy:
        print(f"note: scan in progress ({', '.join(busy)}), so check and apply would defer")

    scanner_id = builtin_id("scanner", state["scanner"], "<get_scanners/>")
    config_id = builtin_id("config", state["scan_config"], '<get_configs filter="rows=-1"/>')
    port_list_id = builtin_id("port_list", state["port_list"], '<get_port_lists filter="rows=-1"/>')

    targets = by_id(call('<get_targets filter="rows=-1"/>'), "target")
    schedules = by_id(call('<get_schedules filter="rows=-1"/>'), "schedule")
    credentials = by_id(call('<get_credentials filter="rows=-1"/>'), "credential")
    users = by_id(call("<get_users/>"), "user")

    plan = []  # (description, function)
    ids = {"credential": {}, "schedule": {}, "target": {}}

    # Users: same name, modified in place. An existing user of that name that
    # Puppet didn't create is adopted, since the name is what the consumer logs
    # in with. Passwords can't be read back, so the digest in the comment
    # is how a rotation is noticed.
    desired_users = {u["name"] for u in state.get("users", [])}
    for u in state.get("users", []):
        d = digest(u)
        role_id = builtin_id("role", u["role"], "<get_roles/>")
        found = next((e for e in users.values() if text(e, "name") == u["name"]), None)
        body = (f"<comment>{escape(stamp(d))}</comment><password>{escape(u['password'])}</password>"
                f"<role id={quoteattr(role_id)}/>")
        if found is None:
            plan.append((f"create user {u['name']}",
                         lambda u=u, body=body: call(f"<create_user><name>{escape(u['name'])}</name>{body}</create_user>")))
        elif text(found, "comment") != stamp(d):
            verb = "update" if managed(found) else "adopt"
            plan.append((f"{verb} user {u['name']}",
                         lambda body=body, uid=found.get("id"): call(f"<modify_user user_id={quoteattr(uid)}>{body}</modify_user>")))

    # Credentials: same name, modified in place when the definition changes.
    for c in state["credentials"]:
        d = digest(c)
        found = next((e for e in credentials.values() if managed(e) and text(e, "name") == c["name"]), None)
        if c["type"] == "usk":
            secret = f"<key><private>{escape(c['private_key'])}</private></key>"
        else:
            secret = f"<password>{escape(c['password'])}</password>"
        if found is None:
            def create(c=c, d=d, secret=secret):
                r = call(f"<create_credential><name>{escape(c['name'])}</name><comment>{escape(stamp(d))}</comment>"
                         f"<type>{c['type']}</type><login>{escape(c['login'])}</login>{secret}</create_credential>")
                ids["credential"][c["name"]] = r.get("id")
            plan.append((f"create credential {c['name']}", create))
            ids["credential"][c["name"]] = None
        else:
            ids["credential"][c["name"]] = found.get("id")
            if text(found, "comment") != stamp(d):
                def modify(c=c, d=d, secret=secret, cid=found.get("id")):
                    call(f"<modify_credential credential_id={quoteattr(cid)}><comment>{escape(stamp(d))}</comment>"
                         f"<login>{escape(c['login'])}</login>{secret}</modify_credential>")
                plan.append((f"update credential {c['name']}", modify))

    # Schedules: same name, modified in place.
    for s in state["schedules"]:
        d = digest(s)
        found = next((e for e in schedules.values() if managed(e) and text(e, "name") == s["name"]), None)
        body = f"<icalendar>{escape(s['icalendar'])}</icalendar><timezone>{escape(s['timezone'])}</timezone>"
        if found is None:
            def create(s=s, d=d, body=body):
                r = call(f"<create_schedule><name>{escape(s['name'])}</name><comment>{escape(stamp(d))}</comment>{body}</create_schedule>")
                ids["schedule"][s["name"]] = r.get("id")
            plan.append((f"create schedule {s['name']}", create))
            ids["schedule"][s["name"]] = None
        else:
            ids["schedule"][s["name"]] = found.get("id")
            if text(found, "comment") != stamp(d):
                def modify(s=s, d=d, body=body, sid=found.get("id")):
                    call(f"<modify_schedule schedule_id={quoteattr(sid)}><comment>{escape(stamp(d))}</comment>{body}</modify_schedule>")
                plan.append((f"update schedule {s['name']}", modify))

    # Targets: the digest is part of the name, so a change is a new target.
    def want_target(t):
        """Plan the target t describes unless gvmd has it, and record its id under t's name."""
        # Credentials are referenced by name: they're updated in place and keep
        # their ids, so rotating a secret mustn't swap every target. Members are
        # part of the definition, so a renamed certname makes a new target whose
        # comment lists it.
        definition = dict(t, hosts=sorted(t["hosts"]), port_list=state["port_list"])
        d = digest(definition)
        name = f"{t['name']} [{d[:8]}]"
        found = next((e for e in targets.values() if managed(e) and text(e, "name") == name), None)
        if found is not None:
            ids["target"][t["name"]] = found.get("id")
            return
        comment = stamp(d)
        if "members" in t:
            comment += " certnames=" + ",".join(sorted(t["members"]))

        def create(t=t, comment=comment, name=name):
            creds = ""
            if t.get("ssh_credential"):
                creds += (f'<ssh_credential id={quoteattr(ids["credential"][t["ssh_credential"]])}>'
                          f'<port>{int(t.get("ssh_port", 22))}</port></ssh_credential>')
            if t.get("smb_credential"):
                creds += f'<smb_credential id={quoteattr(ids["credential"][t["smb_credential"]])}/>'
            r = call(f"<create_target><name>{escape(name)}</name><comment>{escape(comment)}</comment>"
                     f"<hosts>{escape(','.join(sorted(t['hosts'])))}</hosts><exclude_hosts></exclude_hosts>"
                     f"<port_list id={quoteattr(port_list_id)}/>{creds}"
                     f"<alive_tests>{escape(t['alive_test'])}</alive_tests></create_target>")
            ids["target"][t["name"]] = r.get("id")
        plan.append((f"create target {name} ({len(t['hosts'])} hosts)", create))
        ids["target"][t["name"]] = None

    for t in state["targets"]:
        want_target(t)

    def schedule_id(k):
        return ids["schedule"][k["schedule"]] if k.get("schedule") else None

    # Tasks: same name; repoint the target and schedule, reset preferences.
    desired_task_names = set()
    for k in state["tasks"]:
        desired_task_names.add(k["name"])
        prefs = {"max_checks": str(k["max_checks"]), "max_hosts": str(k["max_hosts"])}
        observers = " ".join(sorted(k.get("observers", [])))
        pref_xml = "<preferences>" + "".join(
            f"<preference><scanner_name>{n}</scanner_name><value>{v}</value></preference>" for n, v in prefs.items()
        ) + "</preferences>"
        comment = stamp(digest(dict(k, scanner=state["scanner"], scan_config=state["scan_config"])))
        found = next((e for e in tasks.values() if managed(e) and text(e, "name") == k["name"]), None)
        if found is None:
            def create(k=k, comment=comment, pref_xml=pref_xml, observers=observers):
                schedule = f"<schedule id={quoteattr(schedule_id(k))}/>" if schedule_id(k) else ""
                call(f"<create_task><name>{escape(k['name'])}</name><comment>{escape(comment)}</comment>"
                     f"<config id={quoteattr(config_id)}/><target id={quoteattr(ids['target'][k['target']])}/>"
                     f"<scanner id={quoteattr(scanner_id)}/>{schedule}"
                     f"<alterable>1</alterable><observers>{escape(observers)}</observers>{pref_xml}</create_task>")
            plan.append((f"create task {k['name']}", create))
            continue
        tid = found.get("id")
        current_prefs = {text(p, "scanner_name"): text(p, "value") for p in found.findall("preferences/preference")}
        target_now = found.find("target").get("id") if found.find("target") is not None else ""
        schedule_now = found.find("schedule").get("id") if found.find("schedule") is not None else ""
        changes = []
        if ids["target"][k["target"]] != target_now:
            changes.append("target")
        # gvmd reports a task with no schedule as an empty id.
        # A schedule still to be created has no id yet, but still needs pointing at.
        if (schedule_id(k) or "") != schedule_now or (k.get("schedule") and schedule_id(k) is None):
            changes.append("schedule")
        if any(current_prefs.get(n) != v for n, v in prefs.items()):
            changes.append("preferences")
        # gvmd lists observing users as text, then any groups and roles as
        # elements; only users are managed here.
        if " ".join(sorted((found.findtext("observers") or "").split())) != observers:
            changes.append("observers")
        if text(found, "comment") != comment:
            changes.append("comment")
        if changes:
            def modify(k=k, tid=tid, comment=comment, pref_xml=pref_xml, observers=observers):
                call(f"<modify_task task_id={quoteattr(tid)}><comment>{escape(comment)}</comment>"
                     f"<target id={quoteattr(ids['target'][k['target']])}/>"
                     f"<schedule id={quoteattr(schedule_id(k) or '0')}/>"
                     f"<observers>{escape(observers)}</observers>{pref_xml}</modify_task>")
            plan.append((f"update task {k['name']} ({', '.join(changes)})", modify))

    # New hosts, compared with the certnames listed by the targets the managed
    # tasks point at now. Read before this apply repoints anything.
    family_tasks = {text(e, "name"): e for e in tasks.values()
                    if managed(e) and not text(e, "name").endswith(NEW_HOSTS)}
    one_offs = {text(e, "name"): e for e in tasks.values() if managed(e) and text(e, "name").endswith(NEW_HOSTS)}
    previous = set()
    for e in family_tasks.values():
        known = listed(targets.get(target_of(e)))
        if known is None:
            previous = None
            break
        previous |= known
    if not family_tasks:
        previous = None
    enabled = bool(state.get("new_host_scan"))
    keep_one_offs = set()
    starts = []
    for k in state["tasks"]:
        t = next(x for x in state["targets"] if x["name"] == k["target"])
        members = t.get("members") or {}
        name = k["name"] + NEW_HOSTS
        one_off = one_offs.get(name)
        family = family_tasks.get(k["name"])
        new = set(members) - previous if enabled and previous is not None else set()
        standing = (enabled and one_off is not None and
                    not (family is not None and last_end(family) > (last_end(one_off) or text(one_off, "modification_time"))))
        if not new:
            if standing:
                keep_one_offs.add(name)
                ids["target"][name] = target_of(one_off)
            continue
        # Hosts a standing one-off already covers stay in it, so its next report
        # still has them. One that has been superseded goes first, with its
        # report, so that report can't be read while the new scan runs.
        carried = (listed(targets.get(target_of(one_off))) or set()) if standing else set()
        if one_off is not None and not standing:
            plan.append((f"delete task {name}",
                         lambda tid=one_off.get("id"): call(f'<delete_task task_id={quoteattr(tid)} ultimate="1"/>')))
            one_off = None
        scope = {c: ip for c, ip in members.items() if c in new or c in carried}
        want_target(dict(t, name=name, members=scope, hosts=sorted(set(scope.values()))))
        keep_one_offs.add(name)
        task = dict(k, name=name, target=name, schedule=None)
        prefs = {"max_checks": str(task["max_checks"]), "max_hosts": str(task["max_hosts"])}
        pref_xml = "<preferences>" + "".join(
            f"<preference><scanner_name>{n}</scanner_name><value>{v}</value></preference>" for n, v in prefs.items()
        ) + "</preferences>"
        observers = escape(" ".join(sorted(task.get("observers", []))))
        comment = escape(stamp(digest(dict(task, scanner=state["scanner"], scan_config=state["scan_config"]))))
        tid = {"id": one_off.get("id") if one_off is not None else None}
        if one_off is None:
            def create(name=name, comment=comment, pref_xml=pref_xml, observers=observers, tid=tid):
                r = call(f"<create_task><name>{escape(name)}</name><comment>{comment}</comment>"
                         f"<config id={quoteattr(config_id)}/><target id={quoteattr(ids['target'][name])}/>"
                         f"<scanner id={quoteattr(scanner_id)}/>"
                         f"<alterable>1</alterable><observers>{observers}</observers>{pref_xml}</create_task>")
                tid["id"] = r.get("id")
            plan.append((f"create task {name}", create))
        else:
            def modify(name=name, comment=comment, pref_xml=pref_xml, observers=observers, tid=tid):
                call(f"<modify_task task_id={quoteattr(tid['id'])}><comment>{comment}</comment>"
                     f"<target id={quoteattr(ids['target'][name])}/>"
                     f"<observers>{observers}</observers>{pref_xml}</modify_task>")
            plan.append((f"update task {name} (target)", modify))
        starts.append((f"start task {name} ({', '.join(sorted(new))})",
                       lambda tid=tid: call(f"<start_task task_id={quoteattr(tid['id'])}/>")))

    # Removal. Managed objects that are no longer desired always go; everything
    # else only when purge is on. Order matters: tasks free their targets and
    # schedules, targets free their credentials.
    def removable(e, keep):
        return (managed(e) and not keep(e)) or (purge and not managed(e))

    for tid, e in tasks.items():
        if removable(e, lambda x: text(x, "name") in desired_task_names or text(x, "name") in keep_one_offs):
            plan.append((f"delete task {text(e, 'name')}",
                         lambda tid=tid: call(f'<delete_task task_id={quoteattr(tid)} ultimate="1"/>')))
    # Trashed tasks still hold their targets: gvmd reports such a target as
    # in_use 0 and then refuses to delete it ("Target is in use"), so the trash
    # is emptied before any target, schedule or credential goes.
    if purge:
        trashed = 0
        for kind in ("task", "target", "schedule", "credential", "alert", "config", "port_list", "filter"):
            trashed += len(call(f'<get_{kind}s filter="rows=-1" trash="1"/>').findall(kind))
        if trashed:
            plan.append((f"empty trashcan ({trashed} object(s))", lambda: call("<empty_trashcan/>")))

    for tid, e in targets.items():
        if removable(e, lambda x: tid in ids["target"].values()):
            plan.append((f"delete target {text(e, 'name')}",
                         lambda tid=tid: call(f'<delete_target target_id={quoteattr(tid)} ultimate="1"/>')))
    for sid, e in schedules.items():
        if removable(e, lambda x: text(x, "name") in ids["schedule"]):
            plan.append((f"delete schedule {text(e, 'name')}",
                         lambda sid=sid: call(f'<delete_schedule schedule_id={quoteattr(sid)} ultimate="1"/>')))
    for cid, e in credentials.items():
        if removable(e, lambda x: text(x, "name") in ids["credential"]):
            plan.append((f"delete credential {text(e, 'name')}",
                         lambda cid=cid: call(f'<delete_credential credential_id={quoteattr(cid)} ultimate="1"/>')))
    # Users are never purged: the one logged in to do all this is one of them.
    # A user Puppet made and no longer wants goes, with admin inheriting
    # anything it owned.
    for uid, e in users.items():
        if managed(e) and text(e, "name") not in desired_users:
            plan.append((f"delete user {text(e, 'name')}",
                         lambda uid=uid: call(f'<delete_user user_id={quoteattr(uid)} inheritor_name="admin"/>')))

    if purge:
        for kind, xml in (("alert", '<get_alerts filter="rows=-1"/>'),
                          ("override", '<get_overrides filter="rows=-1"/>'),
                          ("note", '<get_notes filter="rows=-1"/>'),
                          ("filter", '<get_filters filter="rows=-1"/>'),
                          ("port_list", '<get_port_lists filter="rows=-1"/>'),
                          ("config", '<get_configs filter="rows=-1"/>')):
            for oid, e in by_id(call(xml), kind).items():
                # Feed objects are referenced, never removed. The feed import owns
                # them as admin, so ownership says nothing; port lists come back
                # predefined=1, but scan configs, "Full and fast" included, come
                # back predefined=0 and writable=0 (gvmd 22.7). Either marks one.
                if text(e, "predefined") == "1" or text(e, "writable") == "0":
                    continue
                label = text(e, "name") or text(e, "text")[:40] or oid
                plan.append((f"delete {kind} {label}",
                             lambda kind=kind, oid=oid: call(f'<delete_{kind} {kind}_id={quoteattr(oid)} ultimate="1"/>')))

    # Started last, once everything they reference exists and nothing else is
    # left to change.
    plan += starts

    for desc, _ in plan:
        print(("" if mode == "apply" else "would ") + desc)
    if mode == "plan":
        if not plan:
            print("nothing to do")
        return 0
    if mode == "check":
        return 3 if plan else 0
    for desc, fn in plan:
        fn()
    print(f"applied {len(plan)} change(s)" if plan else "nothing to do")
    return 0


if args.argv[1:2] not in (["check"], ["apply"], ["plan"], ["idle"]) or len(args.argv) != 3:  # noqa: F821
    print("usage: reconcile.gmp.py check|apply|plan|idle STATE_JSON")
    sys.exit(64)
try:
    sys.exit(main(args.argv[1], args.argv[2]))  # noqa: F821
except FeedNotReady as exc:
    print(f"deferred: feed not imported yet ({exc}); nothing changed")
    sys.exit(0)
except RuntimeError as exc:
    print(f"error: {exc}")
    sys.exit(1)
