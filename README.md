# openvas

Greenbone Community Edition (OpenVAS) as a docker compose stack, with what it scans built from PuppetDB.

## What `include openvas` does

On a clean agent, with no Hiera data:

- Installs Docker and the compose plugin
- Brings up the Greenbone stack, and keeps it up across reboots
- Sets a generated admin password
- Creates one scan target and one task per OS family, from the active nodes in PuppetDB
- Pulls feed updates daily and stack images weekly, and skips either while a scan is running

The web UI listens on `https://127.0.0.1:443`. Set `openvas::web_bind_address` to reach it from elsewhere.

## Scans are off by default

Nothing is scanned until you decide it should be, because a scan is network traffic across your whole estate, and it can set off intrusion detection and load production hosts.

With the defaults you can start any task by hand from the web UI. To scan every OS family weekly:

```yaml
openvas::scan_schedule_enabled: true
```

The first runs default to Saturday, 16:00 UTC for RedHat, 18:00 for Debian, 20:00 for Windows, and 22:00 for anything else. Change them with `openvas::scan_schedule_starts` and `openvas::scan_default_start`.

## Requirements

- Ubuntu 24.04. Nothing else is tested yet
- Puppet 8 with PuppetDB. Without PuppetDB the stack still installs, and scan targets are skipped with a warning
- 8 CPUs, 16 GB of memory, and at least 200 GB of disk. The stack uses about 75 GB once settled, and a SCAP data rebuild wants about the size of its own database free again

## The first install takes a while

The first agent run blocks while images download. After that, gvmd spends a long time importing feeds, up to a few hours.

Agent runs stay green during that time. Until gvmd has answered once, the reconciler prints `waiting` or `deferred` and changes nothing. Once gvmd has come up, a gvmd that can't be reached fails the agent run.

## The admin password

Log in to the web UI as `admin`.

If `openvas::admin_password` is unset, the password is generated on the node and never enters the catalogue:

```sh
sudo grep '^password' /opt/greenbone-community-container/gvm-admin.conf
```

To choose your own, set it with eyaml:

```yaml
openvas::admin_password: ENC[PKCS7,...]
```

If somebody changes the password in the web UI, Puppet puts it back on the next run. In either case, `%` appears as `%%` in that file.

## Credentialed scans

Without credentials, hosts are scanned from the outside, which finds much less.

```yaml
openvas::scan_ssh_private_key: ENC[PKCS7,...]
openvas::scan_windows_password: ENC[PKCS7,...]
```

These log in as the account named by `openvas::scan_login`, which defaults to `openvas`. This module does not create that account. You need to put it on every scanned node, with the public key on Linux. Windows needs it to be a local administrator, with remote registry access and SMB open to the scanner.

Both are forced to `Sensitive` by the module's own `lookup_options`.

## Purge

`openvas::scan_purge` is off by default. Turn it on and everything in gvmd this module did not create is removed, including hand-made tasks and their reports, targets, schedules, credentials, alerts, overrides, notes, and filters. Feed objects (scan configs, port lists) are left alone.

## What can still delete things with purge off

The module leaves its scan targets alone when PuppetDB is down or returns no hosts. It can't tell a partial answer from a real change, though. If an answer leaves out every node in an OS family, that looks the same as the family being retired, so the family's task is deleted, and its reports with it.

## Checking it

```sh
sudo /usr/local/sbin/greenbone-reconcile plan
```

This prints what the reconciler would change, and changes nothing. No output means gvmd already matches.

## Reading reports from another tool

`openvas::scan_observer_user` and `openvas::scan_observer_password` create a read-only gvmd user who can see the managed tasks and their reports and nothing else.

`scan-hosts.json` in the install directory maps each scanned address to its certname, since gvmd only knows addresses. An address claimed by more than one certname is left out.

## Names

Units, the wrapper, and the compose project are named `greenbone-*`, after the product, even though the module is named for the scanner.

See `REFERENCE.md` for every parameter.

## Licence

Apache-2.0, except where `NOTICE` says otherwise.
