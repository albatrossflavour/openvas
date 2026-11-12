# 4. Run a scan

## Why

Nothing is scanned until you decide it should be, because a scan crosses the whole estate. Run the first scan by hand, then decide whether later ones run on a schedule.

## Before you start

- Step 2 done, with `greenbone-reconcile plan` printing `nothing to do`, so the feeds have finished importing
- Step 3 done, if you want credentialed scans
- Whoever watches intrusion detection told, since a scan crosses the whole estate

## Do it

For a first scan, start one task by hand in the web UI: Scans, Tasks, then the start button on `Puppet: <family>`.

To scan every family weekly, turn the schedule on. [Scans are off by default](../configuration.md#scans-are-off-by-default) has the default times and how to move them.

```yaml
openvas::scan_schedule_enabled: true
```

## Done when

In the web UI, under Scans, Tasks, the task's status is `Done` and its report has results. On the scanner:

```sh
sudo /usr/local/sbin/greenbone-reconcile idle
```

prints `idle` once no scan is running. While one runs it prints `busy:` and the task names.

If you added credentials, check for login failures as step 3 describes.

## If it fails

| You see | Because | Do |
|---|---|---|
| A host with nothing found | The scanner can't reach its `networking.ip` | Fix the route, or list it in `openvas::scan_exclude` |
| A task disappeared, with its reports | PuppetDB stopped returning every node in that family | See [What can still delete things with purge off](../configuration.md#what-can-still-delete-things-with-purge-off) |
| Hand-made tasks disappeared | `openvas::scan_purge` is on | See [Purge](../configuration.md#purge) |

## Next

To get the findings into Puppet Enterprise, [get ready for Soundwave](05-soundwave.md).
