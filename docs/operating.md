# Running openvas

## The first install takes a while

The first agent run blocks while images download. After that, gvmd spends a long time importing feeds, up to a few hours.

Agent runs stay green during that time. Until gvmd has answered once, the reconciler prints `waiting` or `deferred` and changes nothing, and the image's default admin password stays live, so keep `web_bind_address` on localhost until then if the network isn't trusted. If gvmd hasn't accepted the admin password a day after the compose file was written, the agent run fails. Once gvmd has come up, a gvmd that can't be reached fails the agent run.

Puppet's default `runtimeout` is one hour. If the first run hits it, the next run carries on from where the images got to.

## Checking it

```sh
sudo /usr/local/sbin/greenbone-reconcile plan
```

This prints what the reconciler would change, and changes nothing. `nothing to do` means gvmd already matches.

## Moving the compose network

`openvas::compose_subnet` sets the compose network's subnet, `172.29.0.0/24` by default. Changing it, or upgrading to 0.3.0 from a stack whose network Docker picked, rewrites `compose.yaml`, and the next agent run runs `docker compose up -d` straight away. Compose 2.31 or later should then recreate the network, though this hasn't been tested on an existing stack yet. That stops every container (some Compose versions recreate them), which interrupts a running scan, so make the change when no scan is running.

A network made by a Compose older than 2.31 carries no config hash, and Compose leaves it on its old subnet. Check what it's on, and move it by hand if it doesn't match:

```sh
sudo docker network inspect greenbone-community-edition_default --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
cd /opt/greenbone-community-container
sudo docker compose down
sudo docker compose up -d
```

`down` without `--volumes` keeps the feed data and reports.

## Removing it

Removing the class leaves everything in place, because deleting scan data should be a decision. To remove the stack by hand:

```sh
sudo systemctl disable --now greenbone-stack.service greenbone-feed-update.timer greenbone-image-update.timer
sudo docker compose -f /opt/greenbone-community-container/compose.yaml down --volumes
sudo rm -rf /opt/greenbone-community-container /usr/local/sbin/greenbone-reconcile
```

`--volumes` deletes every report.

## Names

Units, the wrapper, and the compose project are named `greenbone-*`, after the product, even though the module is named for the scanner.
