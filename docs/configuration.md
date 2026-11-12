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

## Reading reports from another tool

`openvas::scan_observer_user` and `openvas::scan_observer_password` create a read-only gvmd user who can see the managed tasks and their reports and nothing else. Set both or neither, since one on its own fails the catalogue. Soundwave logs in with the same two settings, so they only need setting here.

`scan-hosts.json` in the install directory maps each scanned address to its certname, since gvmd only knows addresses. An address claimed by more than one certname is left out.
