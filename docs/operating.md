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
