# Changelog

## 0.1.0

First release. Installs the Greenbone Community Edition stack on Ubuntu 24.04, and builds scan targets and tasks from PuppetDB. Scheduled scans are off by default.

- `include openvas` needs no Hiera data: the admin password is generated on the node, and credentials are optional
- Agent runs stay green during the first feed import, and fail if gvmd hasn't accepted the password after a day
- Purge is off by default
- `openvas::target` creates the scan account on the nodes being scanned, from the same Hiera values as the scanner, and only warns while those values are missing
