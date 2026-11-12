# 3. Add scan credentials

## Why

Without credentials Greenbone scans from the outside: open ports, services, and TLS. With them it logs in and checks installed packages too, which is where most findings come from. This step is optional.

## Before you start

- Step 2 done
- eyaml, to encrypt the private key and the Windows password
- A profile every scanned node gets, to put `openvas::target` in

## Do it

Follow [Credentialed scans](../../README.md#credentialed-scans): make a key, put the key and the Windows password in Hiera at a level both the scanner and the scanned nodes read, and include `openvas::target` on the scanned nodes. Then run the agent on the scanned nodes, and on the scanner.

Windows needs more than the account. See [Windows needs more than the account](../../README.md#windows-needs-more-than-the-account).

## Done when

On a Linux node you want scanned:

```sh
getent passwd openvas
sudo grep -c openvas-scan ~openvas/.ssh/authorized_keys
```

The account exists and the key is there once. On the scanner, `sudo /usr/local/sbin/greenbone-reconcile plan` prints `nothing to do`.

The real proof comes after the next scan in step 4. In the web UI, under Scans, Results, filter on `name~"Login Failed"`. A result named `SSH Login Failed For Authenticated Checks` or `SMB Login Failed For Authenticated Checks` names a host the scanner couldn't log in to. None means every login worked.

## If it fails

| You see | Because | Do |
|---|---|---|
| `openvas::target: ... is not set, so no scan account is created` | The node can't read the public key or the Windows password | Put them at a Hiera level the scanned nodes read, such as `common.yaml` |
| The catalogue fails naming a key clash | Another scanner uses the same key name with a different key | See [Sharing the account with another scanner](../../README.md#sharing-the-account-with-another-scanner) |
| SSH login fails on some hosts | TCP 22 blocked from the scanner, or the account not created yet | Check the route, and that the agent has run on that node |
| SMB login fails, or Windows hosts have very few findings | SMB, remote registry, or `LocalAccountTokenFilterPolicy` | See the Windows section linked above |

## Next

[Run a scan](04-scan.md).
