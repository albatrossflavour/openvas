# openvas

Greenbone Community Edition (OpenVAS) as a docker compose stack, with what it scans built from PuppetDB.

## Two classes, on two kinds of node

| Class | Goes on | Does |
|---|---|---|
| `openvas` | the scanner | Installs and runs Greenbone, and decides what gets scanned, when, and with which credentials. Everything is a parameter on this class |
| `openvas::target` | every node you want scanned with credentials | Creates the account the scanner logs in as. Put it in a profile every node gets |

They are separate because Puppet only changes the node it is running on. The scanner's catalogue can't create an account on another node, so each scanned node does that in its own.

You only need `openvas::target` for credentialed scans. Without it the scanner still scans every node, from the outside. It is safe to include everywhere before the credentials are in Hiera: it warns and changes nothing until they are.

## What `include openvas` does

On a clean agent, with no Hiera data:

- Installs Docker and the compose plugin
- Brings up the Greenbone stack, and keeps it up across reboots
- Sets a generated admin password
- Creates one scan target and one task per OS family, from the active nodes in PuppetDB
- Pulls feed updates daily and stack images weekly, and skips either while a scan is running

The web UI listens on `https://127.0.0.1:443`. Set `openvas::web_bind_address` to an IPv4 address to reach it from elsewhere.

`examples/` has the scanner with and without schedules and credentials, and a scanned node.

## Scans are off by default

Nothing is scanned until you decide it should be, because a scan is network traffic across your whole estate, and it can set off intrusion detection and load production hosts.

With the defaults you can start any task by hand from the web UI. To scan every OS family weekly:

```yaml
openvas::scan_schedule_enabled: true
```

The first runs default to Saturday, 16:00 UTC for RedHat, 18:00 for Debian, and 20:00 for Windows, and each repeats weekly on that day and time. To move one, set it in `openvas::scan_schedule_starts`. Hiera merges that hash into the defaults, so the families you don't list keep theirs.

```yaml
openvas::scan_schedule_starts:
  windows: '20261110T130000Z'
```

The merge only happens through Hiera. A hash passed as a class parameter replaces the defaults, and a family left out of it falls back to `openvas::scan_default_start`.

Times are UTC, in iCalendar form. The date only sets the first run, so that Windows scan runs every Tuesday at 13:00 UTC.

`openvas::scan_default_start` (Saturday, 22:00 UTC) is only for OS families with no entry in `scan_schedule_starts`. With the default hash that's none of RedHat, Debian, or Windows, so setting it on its own moves nothing.

## Requirements

- Ubuntu 24.04, where it runs in production. A bare install on AlmaLinux 9 and 10 and Ubuntu 26.04 was tested on 2026-11-09, without running a scan
- Puppet 8 with PuppetDB. Without PuppetDB the stack still installs, and scan targets are skipped with a warning
- An agent certificate. Credentials are encrypted to it with `node_encrypt`, so `puppet apply` on a node that has never joined a Puppet server fails
- On EL10, a reboot after the first run. `docker-ce` pulls in `kernel-modules-extra` for the newest kernel, and Docker can't start until that kernel is running
- 8 CPUs, 16 GB of memory, and at least 200 GB of disk. The stack uses about 75 GB once settled, and a SCAP data rebuild wants about the size of its own database free again

## The first install takes a while

The first agent run blocks while images download. After that, gvmd spends a long time importing feeds, up to a few hours.

Agent runs stay green during that time. Until gvmd has answered once, the reconciler prints `waiting` or `deferred` and changes nothing, and the image's default admin password stays live, so keep `web_bind_address` on localhost until then if the network isn't trusted. If gvmd hasn't accepted the admin password a day after the compose file was written, the agent run fails. Once gvmd has come up, a gvmd that can't be reached fails the agent run.

Puppet's default `runtimeout` is one hour. If the first run hits it, the next run carries on from where the images got to.

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

If somebody changes the password in the web UI, Puppet puts it back on the next run. In either case, `%` appears as `%%` in that file. A password can't start or end with whitespace, and the catalogue fails to compile if it does.

If you unset `openvas::admin_password` later, the file Puppet wrote stays in place and keeps its password.

## Credentialed scans

Without credentials, hosts are scanned from the outside, which finds much less. Credentials need three steps: a key and a password for the scanner, and an account on the nodes.

### 1. Make the SSH key

The module has no passphrase setting, so make the key without one:

```sh
ssh-keygen -t rsa -b 4096 -N '' -C openvas-scan -f openvas_scan
eyaml encrypt -l openvas::scan_ssh_private_key -f openvas_scan
```

Keep `openvas_scan.pub` for step 2, and delete the private key file once it's encrypted.

### 2. Put the credentials in Hiera

At a level both the scanner and the scanned nodes read, such as `common.yaml`:

```yaml
openvas::scan_ssh_private_key: ENC[PKCS7,...]                                # the scanner logs in to Linux with this
openvas::target::ssh_public_key: "ssh-rsa AAAAB3Nza... openvas-scan"          # Linux nodes accept this
openvas::scan_windows_password: ENC[PKCS7,...]                               # the scanner and Windows nodes share this
```

The scanner turns each credential on when it is set, and scans that OS family from the outside when it isn't. There is no separate switch. The secrets are forced to `Sensitive` by the module's own `lookup_options`.

### 3. Include `openvas::target` on the scanned nodes

```puppet
include openvas::target
```

On Linux it creates an account with a home directory, a shell, and the public key. It needs no sudo, because the local checks read package lists any user can read. On Windows it creates a local administrator with the scan password. Without its value it warns and creates nothing.

### Choosing the account

The scanner logs in as `openvas::scan_login`, which defaults to `openvas`, and `openvas::target` creates an account of the same name. Set it once to change both.

To use an account that already exists, or that something else manages, set `openvas::target::manage_user: false`. On Linux the class then only adds the public key to that account, and on Windows it does nothing, so the account needs to be a local administrator already.

### Sharing the account with another scanner

The key is added as `openvas-scan` by default, and `openvas::target::ssh_key_name` changes that. When another scanner logs in as the same account with the same key, give both the same key name: the key is declared once and appears once in `authorized_keys`. The same name with a different key fails the catalogue, naming the clash, rather than one of them quietly winning.

### Windows needs more than the account

Remote registry access, and SMB (445) open from the scanner. A local administrator logging in over the network also gets a filtered token unless `LocalAccountTokenFilterPolicy` is 1 under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`. Without it the scan logs in but can't read the registry, so most Windows checks don't run. The module doesn't manage these.

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

## Removing it

Removing the class leaves everything in place, because deleting scan data should be a decision. To remove the stack by hand:

```sh
sudo systemctl disable --now greenbone-stack.service greenbone-feed-update.timer greenbone-image-update.timer
sudo docker compose -f /opt/greenbone-community-container/compose.yaml down --volumes
sudo rm -rf /opt/greenbone-community-container /usr/local/sbin/greenbone-reconcile
```

`--volumes` deletes every report.

## Limitations

- Ubuntu 24.04 and 26.04 and AlmaLinux 9 and 10, and IPv4 only for the web UI
- One target and one task per OS family, with the `Full and fast` scan config and the `All IANA assigned TCP` port list
- Each node is scanned at its primary address, from the `networking.ip` fact. A node whose primary address the scanner can't reach still appears, and comes back with nothing found, so use `openvas::scan_exclude` for those
- The images track Greenbone's `stable` and `latest` tags and update weekly, so a Greenbone release reaches you without a module release
- The module has been run for real on one estate. It has no Litmus acceptance tests, because the stack needs tens of GB of feed data and privileged containers

## Development

```sh
pdk validate
pdk test unit
uvx pytest spec/python
```

The Python tests cover the reconciler against a fake gvmd, and the wrapper against a stub `docker`. Neither needs Docker. `pdk test unit` fails below 100% resource coverage.

## Names

Units, the wrapper, and the compose project are named `greenbone-*`, after the product, even though the module is named for the scanner.

See `REFERENCE.md` for every parameter.

## Licence

Apache-2.0, except `templates/compose.yaml.epp`. That file is adapted from Greenbone's, and stays CC-BY-SA-4.0, as `docs/compose-licence.txt` explains.
