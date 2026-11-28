# Configuring openvas

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

### New nodes are scanned straight away

With the schedule on, a node that joins the scan scope is scanned on the scanner's next agent run rather than at its family's weekly run. The run that adds it to a target also creates and starts `Puppet: <family> new hosts`, a task over only the nodes that weren't in scope at the last run, with the family's credentials and observers and no schedule. Each target lists its certnames in its comment, which is how the next run tells what is new. A node is known by its certname, so one whose address changes isn't new, and one that leaves and comes back is. Upgrading, or a first install, scans nothing extra.

It never starts while a scan is running. Like every other change the module makes, it waits, and the first agent run after the scan finishes starts it.

Its report sits beside the weekly ones, so anything reading each task's last report, Soundwave included, sees the new nodes. Once the family's own task has a newer report, which covers them, the next agent run deletes the new-hosts task and its report, so its findings don't outlive a fix. More new nodes before then join it and it runs again.

To keep to the schedule alone:

```yaml
openvas::scan_new_hosts: false
```

## Feed updates

The feed ships as data container images. Every day at 05:53, node time, `greenbone-feed-update.timer` pulls them and recreates the data containers, which copy the new data in. A run is skipped while a scan is going, and a run missed while the node was off isn't caught up at boot, because recopying the feed under a scanner that's still starting interrupts it.

On a node that's off at 05:53, or always scanning then, the feed never updates. Move the run to a time the node is up and idle:

```yaml
openvas::feed_update_schedule: 'Mon..Fri *-*-* 10:00:00'
```

The value is a systemd `OnCalendar` expression. `systemctl list-timers greenbone-feed-update.timer` shows the next and last run, and `-` under LAST means it has never fired since systemd started. To refresh now, while no scan is running, run `sudo systemctl start greenbone-feed-update.service`.

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

### A domain account for Windows

Windows hosts can log in as their own account, such as a domain account that is a local administrator on each member, while Linux keeps `openvas::scan_login`. Set `openvas::scan_windows_login`, and the SMB credential logs in as it with `openvas::scan_windows_password`. Set `openvas::target::manage_user: false` on Windows so no local account is created.

When only some Windows hosts know that account, such as domain members beside workgroup nodes, `openvas::scan_windows_smb_filter` takes a PQL condition on the active Windows nodes. The ones it matches get the `Puppet: Windows` target with the SMB credential, and the rest get `Puppet: Windows unauthenticated`, scanned without it, so they're never offered the login. If PuppetDB can't answer, no host gets the credential. Both tasks run on the weekly Windows schedule.

```yaml
openvas::scan_windows_login: 'EXAMPLE\svc-scan'
openvas::scan_windows_smb_filter: 'facts.ad_domain_role = 3'
openvas::scan_windows_password: ENC[PKCS7,...]
```

A domain account's network logon isn't filtered the way a local administrator's is, so `LocalAccountTokenFilterPolicy` below isn't needed for it.

### Windows needs more than the account

Remote registry access, and SMB (445) open from the scanner. A local administrator logging in over the network also gets a filtered token unless `LocalAccountTokenFilterPolicy` is 1 under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`. Without it the scan logs in but can't read the registry, so most Windows checks don't run. The module doesn't manage these.

## Purge

`openvas::scan_purge` is off by default. Turn it on and everything in gvmd this module did not create is removed, including hand-made tasks and their reports, targets, schedules, credentials, alerts, overrides, notes, and filters. Feed objects (scan configs, port lists) are left alone.

## What can still delete things with purge off

The module leaves its scan targets alone when PuppetDB is down or returns no hosts. It can't tell a partial answer from a real change, though. If an answer leaves out every node in an OS family, that looks the same as the family being retired, so the family's task is deleted, and its reports with it.

## Reading reports from another tool

`openvas::scan_observer_user` and `openvas::scan_observer_password` create a read-only gvmd user who can see the managed tasks and their reports and nothing else. Set both or neither, since one on its own fails the catalogue. [Soundwave](https://github.com/albatrossflavour/soundwave) logs in with the same two settings, so they only need setting here.

`scan-hosts.json` in the install directory maps each scanned address to its certname, since gvmd only knows addresses. An address claimed by more than one certname is left out.
