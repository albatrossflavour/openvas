# Changelog

## 0.4.0

- `openvas::scan_windows_login` sets the account the SMB credential logs in as, such as a domain account, while SSH keeps `openvas::scan_login`. Unset, nothing changes
- `openvas::scan_windows_smb_filter`, a PQL condition, splits Windows hosts into `Puppet: Windows`, which gets the SMB credential, and `Puppet: Windows unauthenticated` for the rest, so hosts outside the filter are never offered the login. Unset, there is one Windows target as before

## 0.3.0

- `openvas::compose_subnet` puts the compose network on a fixed subnet, `172.29.0.0/24` by default, so the scanner's scan of itself comes from a known range. On an existing stack, Compose 2.31 or later should recreate the network on the next agent run, though this hasn't been tested on an existing stack yet. Recreating the network stops every container (some Compose versions recreate them), which interrupts a running scan, so upgrade when no scan is running. A network made by an older Compose keeps its old subnet: see [Moving the compose network](https://github.com/albatrossflavour/openvas/blob/main/docs/operating.md#moving-the-compose-network)
- Supports Puppet 9, `puppet-logrotate` 9.x and 10.x, and `puppetlabs-node_encrypt` 4.x, so `pe_status_check` stops reporting the module's dependency caps

## 0.2.0

- `openvas::feed_update_schedule` sets when the feed refresh runs, for a node that's off or scanning at the default 05:53

## 0.1.1

- The README links to the docs on GitHub, so they work on the Forge

## 0.1.0

First release. Installs the Greenbone Community Edition stack on Ubuntu 24.04 and 26.04 and AlmaLinux 9 and 10, and builds scan targets and tasks from PuppetDB. Scheduled scans are off by default.

- An install guide in `docs/guide/`, from an empty node to a finished scan and on to Soundwave, with a check for each step that says what a good answer looks like
- `include openvas` needs no Hiera data: the admin password is generated on the node, and credentials are optional
- Agent runs stay green during the first feed import, and fail if gvmd hasn't accepted the password after a day
- Purge is off by default
- `openvas::target` creates the scan account on the nodes being scanned, from the same Hiera values as the scanner, and only warns while those values are missing
- `openvas::target::ssh_key_name` names the authorised key, so a second scanner sharing the account and key declares it once
- `openvas::scan_schedule_starts` merges through Hiera, so moving one OS family's start leaves the others on their defaults
- `openvas::scan_observer_user` and `openvas::scan_observer_password` have to be set together, and the catalogue fails if only one is
