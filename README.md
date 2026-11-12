# openvas

This module runs [Greenbone Community Edition](https://greenbone.github.io/docs/latest/) (OpenVAS) against every node in your Puppet estate, with the scan list kept in step with PuppetDB, so a new node is scanned without anyone editing Greenbone. Greenbone finds network, TLS, and configuration problems from the outside, and with credentials it logs in to check installed packages too.

It works on its own, with Greenbone's web UI for the reports. [Soundwave](https://github.com/albatrossflavour/soundwave) pushes its findings, with any other scanner's, into [Vulnerability Remediation](https://help.puppet.com/pe/current/topics/advanced-patching-vulnerability-remediation.htm) in Puppet Enterprise Advanced, where PE shows which ones Puppet can patch.

## What it installs

| Class | Goes on | Does |
|---|---|---|
| `openvas` | the scanner | Installs and runs Greenbone, and decides what gets scanned, when, and with which credentials. Everything is a parameter on this class |
| `openvas::target` | every node you want scanned with credentials | Creates the account the scanner logs in as. Put it in a profile every node gets |

`openvas::target` is only needed for credentialed scans, and is safe to include everywhere before the credentials are in Hiera, because until then it warns and changes nothing.

### What `include openvas` does

On a clean agent, with no Hiera data:

- Installs Docker and the compose plugin
- Brings up the Greenbone stack, and keeps it up across reboots
- Sets a generated admin password
- Creates one scan target and one task per OS family, from the active nodes in PuppetDB
- Pulls feed updates daily and stack images weekly, and skips either while a scan is running
- Schedules no scans. Nothing is scanned until you start a task or turn the schedule on, because a scan crosses the whole estate

The web UI listens on `https://127.0.0.1:443`. Set `openvas::web_bind_address` to an IPv4 address to reach it from elsewhere.

`examples/` has the scanner with and without schedules and credentials, and a scanned node.

Purge is off by default. Even with it off, a PuppetDB answer that leaves out every node in an OS family deletes that family's task and its reports. See [What can still delete things with purge off](docs/configuration.md#what-can-still-delete-things-with-purge-off).

## Requirements

- Ubuntu 24.04 or 26.04, or AlmaLinux 9 or 10
- Puppet 8 with PuppetDB, and an agent certificate, since credentials are encrypted to it with `node_encrypt`
- On EL10, a reboot after the first run. `docker-ce` pulls in `kernel-modules-extra` for the newest kernel, and Docker can't start until that kernel is running
- 8 CPUs, 16 GB of memory, and at least 200 GB of disk. The stack uses about 75 GB once settled, and a SCAP data rebuild wants about the size of its own database free again

## Getting started

Follow [the install guide](docs/guide/README.md). It goes from an empty node to a finished scan, with a check at the end of each step, and on to Soundwave if you want the findings in VR.

## Reference

- Schedules, credentials, the admin password, purge, and reading reports from another tool: [configuration](docs/configuration.md)
- The first install, checking what the reconciler would change, and removing the stack: [operating](docs/operating.md)
- Every class and parameter: [REFERENCE.md](REFERENCE.md)
- What changed in each release: [CHANGELOG.md](CHANGELOG.md)

## Limitations

- IPv4 only for the web UI
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

## Licence

Apache-2.0, except `templates/compose.yaml.epp`. That file is adapted from Greenbone's, and stays CC-BY-SA-4.0, as `docs/compose-licence.txt` explains.
