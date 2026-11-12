# 5. Get ready for Soundwave

## Why

[Soundwave](https://github.com/albatrossflavour/soundwave) reads Greenbone's reports and pushes the findings into Puppet Enterprise Vulnerability Remediation. It reads them as a read-only gvmd user, which this module creates. Soundwave doesn't create that user, so this step comes first.

## Before you start

- Step 4 done, with at least one finished report
- No scan running. The reconciler won't create the user during a scan, so check `sudo /usr/local/sbin/greenbone-reconcile idle` prints `idle`

## Do it

Set both settings, at a level the scanner reads. One without the other fails the catalogue.

```yaml
openvas::scan_observer_user: 'reader'
openvas::scan_observer_password: ENC[PKCS7,...]
```

Then run the agent on the scanner. See [Reading reports from another tool](../configuration.md#reading-reports-from-another-tool) for what the user can see.

## Done when

On the scanner, log in to gvmd as that user. `read -s` keeps the password out of your shell history.

```sh
read -rs P
sudo docker compose -f /opt/greenbone-community-container/compose.yaml run --rm --no-deps -T gvm-tools \
  gvm-cli --gmp-username reader --gmp-password "$P" socket --socketpath /run/gvmd/gvmd.sock --xml '<get_version/>'
```

A good answer contains `status="200"`, such as `<get_version_response status="200" status_text="OK"><version>22.7</version></get_version_response>`.

## If it fails

| You see | Because | Do |
|---|---|---|
| `Response Error 400. Authentication failed` | The user doesn't exist yet, or has another password | Run `sudo /usr/local/sbin/greenbone-reconcile plan`. If it plans to create the user, run the agent again when no scan is running |
| `plan` prints `note: scan in progress` | The reconciler defers while a scan runs | Run the agent once the scan finishes |
| The catalogue fails about `scan_observer_user and scan_observer_password` | Only one of them is set | Set both |

## Next

Continue with [the Soundwave install guide](https://github.com/albatrossflavour/soundwave/blob/main/docs/guide/README.md). Soundwave picks up these two settings and the module's host map by itself, so you don't set them again there.
