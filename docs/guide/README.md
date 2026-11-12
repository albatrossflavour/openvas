# Installing Greenbone

This guide takes you from an empty node to Greenbone scanning every node in PuppetDB, and optionally on to the findings showing up in Puppet Enterprise.

The steps link to [the module's reference pages](../../README.md#reference) for each setting's detail.

## Which steps you need

Everyone does steps 1, 2, and 4. Greenbone works on its own, and nothing here needs Puppet Enterprise until step 5.

| You want | Steps |
|---|---|
| Greenbone scanning from the outside | 1, 2, and 4 |
| Credentialed scans, which find much more | 1, 2, 3, and 4 |
| The findings in PE Vulnerability Remediation | All five, then [the Soundwave guide](https://github.com/albatrossflavour/soundwave/blob/main/docs/guide/README.md) |
| Credentials added to a scanner you already run | 3, then a scan from step 4 |

## The steps

1. [Plan the scanner](01-plan.md)
2. [Install the stack](02-install.md)
3. [Add scan credentials](03-credentials.md)
4. [Run a scan](04-scan.md)
5. [Get ready for Soundwave](05-soundwave.md)

## Upgrading

Greenbone's images update weekly by themselves, outside a scan, so a Greenbone release needs nothing from you. A module upgrade is a Puppetfile change like any other, and needs no step of its own.
