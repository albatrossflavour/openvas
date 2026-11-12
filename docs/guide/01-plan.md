# 1. Plan the scanner

## Why

A node too small for Greenbone fails part way through the feed import hours after the install looked fine, and a scanner that can't reach a node reports it as clean rather than failing.

## Before you start

- Puppet 8 with PuppetDB. The scan list comes from PuppetDB, so without it nothing is scanned
- eyaml, for the secrets in steps 2, 3, and 5, and for Soundwave's token

## Do it

Pick a node that meets the [requirements](../../README.md#requirements): 8 CPUs, 16 GB of memory, and 200 GB of disk, on Ubuntu 24.04 or 26.04 or AlmaLinux 9 or 10. It needs an agent certificate, so join it to the Puppet server before going further.

Check the network from that node:

- Outbound HTTPS to pull images and feeds
- Every node you want scanned, at its `networking.ip` fact, since that's the address it's scanned at
- TCP 22 to Linux nodes and TCP 445 to Windows nodes, if you'll add credentials in step 3

Decide when scans may run. A scan is traffic across the whole estate and can set off intrusion detection, which is why the module schedules nothing until you say so. See [Scans are off by default](../configuration.md#scans-are-off-by-default).

## Done when

On the scanner:

```sh
nproc; free -g | awk '/Mem/ {print $2 " GB"}'; df -h /var /opt
sudo puppet agent -t
```

At least 8 CPUs, about 16 GB, and 200 GB free where Docker and `/opt` live, and an agent run that completes.

## If it fails

A node whose address the scanner can't reach still gets scanned and comes back with nothing found, so it looks clean. List those in `openvas::scan_exclude`, or fix the route, before trusting a report.

## Next

[Install the stack](02-install.md).
