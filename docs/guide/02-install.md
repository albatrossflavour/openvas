# 2. Install the stack

## Why

This brings up Greenbone and creates a scan target and task for each OS family in PuppetDB.

## Before you start

- Step 1 done
- The module and its dependencies (`puppetlabs-stdlib`, `puppetlabs-docker`, `puppet-systemd`, `puppet-logrotate`, and `puppetlabs-node_encrypt`) in your Puppetfile, and deployed to the scanner's environment
- Expect the first run to take a while. Images download during the agent run, and gvmd then imports feeds for up to a few hours
- Optionally, your own admin password in Hiera. See [The admin password](../../README.md#the-admin-password). Without one it's generated on the node

## Do it

Add the class to the scanner's profile, and run the agent:

```puppet
include openvas
```

```sh
sudo puppet agent -t
```

[What `include openvas` does](../../README.md#what-include-openvas-does) lists everything this sets up. Leave `openvas::web_bind_address` on its default of localhost until gvmd is up, because the image's default admin password is live until then. See [The first install takes a while](../../README.md#the-first-install-takes-a-while).

## Done when

```sh
systemctl is-active greenbone-stack.service
sudo /usr/local/sbin/greenbone-reconcile plan
```

The first prints `active`. The second prints `nothing to do` once gvmd is up and matches what Puppet wants. While gvmd is still importing it prints `waiting: gvmd is not ready yet`, which is normal for the first few hours, so run the agent again later.

Then log in to the web UI as `admin`. If you didn't set a password, `sudo grep '^password' /opt/greenbone-community-container/gvm-admin.conf` shows the generated one, with any `%` written as `%%`, so type a single `%`. Under Scans, Tasks, there's a task named `Puppet: <family>` for each OS family PuppetDB has, such as `Puppet: Debian`.

## If it fails

| You see | Because | Do |
|---|---|---|
| The agent run hits its one hour `runtimeout` | Images are still downloading | Run it again. It carries on from where the download got to |
| Docker won't start on EL10 | `docker-ce` pulled in a kernel module for a newer kernel | Reboot, then run the agent |
| `openvas::scans: PuppetDB returned no hosts; scan targets left untouched`, or `openvas::puppetdb_rows:` warnings | PuppetDB couldn't be queried, or holds no active nodes | Fix that and run the agent again |
| `gvmd has not accepted the admin password in a day` | gvmd never came up | `sudo docker compose -f /opt/greenbone-community-container/compose.yaml logs gvmd` |
| No task for an OS family | PuppetDB has no active node in that family | Nothing to fix |

## Next

[Add scan credentials](03-credentials.md), or skip to [Run a scan](04-scan.md) to scan from the outside only.
