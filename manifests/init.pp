# @summary
#   Greenbone Community Edition (OpenVAS) as a docker compose stack, with what
#   it scans built from PuppetDB.
#
#   A bare include installs Docker, brings up the stack, sets an admin password,
#   and creates one target and one task per OS family. Nothing is scanned until
#   you start a task or set `scan_schedule_enabled`.
#
# @example Install, with scans started by hand
#   include openvas
#
# @example Scan weekly
#   class { 'openvas':
#     scan_schedule_enabled => true,
#   }
#
# @param install_dir
#   Directory holding compose.yaml and the reconciler's files. Letters, digits,
#   dots, dashes, underscores, and slashes only, as it ends up in shell commands.
# @param feed_release
#   Vulnerability feed release tracked by the data containers.
# @param feed_update_schedule
#   When the feed images are pulled and the data containers refreshed, as a
#   systemd `OnCalendar` expression in the node's timezone. A run is skipped
#   while a scan is going, and a missed run isn't caught up at boot, so choose a
#   time the node is up and not scanning.
# @param web_bind_address
#   IPv4 host address the web UI binds to, on ports 443 and 9392.
# @param web_certificate
#   PEM certificate the web UI serves on 443. The default is this node's Puppet
#   agent certificate, issued by the PE CA for the node's certname, so a browser
#   or tool that trusts the PE CA trusts the UI. With `web_key` unset too, the
#   stack keeps the self-signed certificate its setup container makes.
# @param web_key
#   The private key for `web_certificate`. Copied into the install directory,
#   root only, and mounted read-only into the nginx container. Set both or neither.
# @param compose_subnet
#   IPv4 subnet of the stack's compose network. Greenbone's scan of the scanner
#   node itself comes from an address in it, so a node that limits where the
#   scan account logs in from can name this subnet exactly. The default sits
#   outside the ranges Docker hands out early and the common LAN ranges. Change
#   it if it collides with a network the scanner has to reach, because the
#   bridge would take that traffic. It must not overlap another Docker network.
#   It is checked only for being an IPv4 subnet, so an overlap, or a prefix
#   with host bits set, fails at `docker compose up` on the node and not when
#   the catalogue compiles.
# @param manage_docker
#   Whether this module installs Docker through the `docker` class.
# @param admin_password
#   Password for the `admin` user. When unset, one is generated on the node and
#   kept in `gvm-admin.conf` in `install_dir`, root only. It can't start or end
#   with whitespace, which gvm-tools strips when it reads the file.
# @param scan_ssh_private_key
#   Private key for credentialed scans of Linux hosts. Unset means those hosts
#   are scanned without logging in, which finds much less.
# @param scan_windows_password
#   Password for credentialed scans of Windows hosts. Unset means those hosts
#   are scanned without logging in, which finds much less.
# @param scan_login
#   Account the scan credentials log in as, on every scanned node.
# @param scan_windows_login
#   Account the SMB credential logs in as, such as a domain account
#   (`ALBATROSSFLAVOUR\svc-lab-scan`). Unset means `scan_login`, as before.
#   The SSH credential always uses `scan_login`.
# @param scan_windows_smb_filter
#   A PQL condition on active Windows nodes, such as
#   `facts.ad_domain_role = 3`. When set, Windows hosts it matches get their
#   own target with the SMB credential, and the rest a target scanned without
#   it (`Puppet: Windows unauthenticated`), so hosts outside it are never
#   offered the login. Unset means one Windows target, as before.
# @param scan_purge
#   Remove every object in gvmd this module did not create, reports included.
# @param scan_schedule_enabled
#   Scan each OS family weekly. When false, targets and tasks exist but nothing
#   starts on its own.
# @param scan_new_hosts
#   With the schedule on, scan a node as soon as it joins the scan scope rather
#   than waiting for its family's weekly run. The agent run that adds it to a
#   target also creates and starts a task of its own, `Puppet: <family> new
#   hosts`, over only the nodes new since the last run, with the family's
#   credentials and observers. A node is known by its certname, so one whose
#   address changes isn't new, and one that leaves and comes back is. Like any
#   other change, it waits while a scan is running and starts on the first run
#   after it finishes. The task is deleted, with its report, once the family's
#   own task has a newer report. Ignored while `scan_schedule_enabled` is false.
# @param scan_exclude
#   Certnames to leave out of the scan scope.
# @param scan_schedule_starts
#   First run per OS family (UTC, iCalendar DTSTART), repeated weekly on that
#   day and time. Defaults (in the module's data) are Saturday 16:00 UTC for
#   RedHat, 18:00 for Debian, and 20:00 for windows. Hiera merges into them, so
#   setting one family leaves the others where they are.
# @param scan_default_start
#   First run for any OS family not in `scan_schedule_starts`. With the default
#   hash that's none of RedHat, Debian, or windows, so this alone moves nothing.
# @param scan_max_hosts
#   Hosts scanned concurrently per task.
# @param scan_max_checks
#   Tests run concurrently per host.
# @param scan_observer_user
#   Optional read-only gvmd user, for anything that pulls reports. It is created
#   with the Observer role and can see the managed tasks and their reports only.
# @param scan_observer_password
#   That user's password. Set both or neither: one without the other fails the
#   catalogue.
class openvas (
  Pattern[/\A\/[\w.\/-]+\z/]     $install_dir            = '/opt/greenbone-community-container',
  String[1]                      $feed_release           = '24.10',
  Pattern[/\A[^\r\n]+\z/]          $feed_update_schedule   = '*-*-* 05:53:00',
  Stdlib::IP::Address::V4::Nosubnet $web_bind_address    = '127.0.0.1',
  Stdlib::IP::Address::V4::CIDR  $compose_subnet         = '172.29.0.0/24',
  Optional[Stdlib::Absolutepath] $web_certificate        = "/etc/puppetlabs/puppet/ssl/certs/${trusted['certname']}.pem",
  Optional[Stdlib::Absolutepath] $web_key                = "/etc/puppetlabs/puppet/ssl/private_keys/${trusted['certname']}.pem",
  Boolean                        $manage_docker          = true,
  Optional[Sensitive[String[1]]] $admin_password         = undef,
  Optional[Sensitive[String[1]]] $scan_ssh_private_key   = undef,
  Optional[Sensitive[String[1]]] $scan_windows_password  = undef,
  String[1]                      $scan_login             = 'openvas',
  Optional[String[1]]            $scan_windows_login     = undef,
  Optional[String[1]]            $scan_windows_smb_filter = undef,
  Boolean                        $scan_purge             = false,
  Boolean                        $scan_schedule_enabled  = false,
  Boolean                        $scan_new_hosts         = true,
  Array[String[1]]               $scan_exclude           = [],
  Hash[String[1], String[1]]     $scan_schedule_starts   = {}, # from data/common.yaml
  String[1]                      $scan_default_start     = '20260912T220000Z',
  Integer[1]                     $scan_max_hosts         = 20,
  Integer[1]                     $scan_max_checks        = 4,
  Optional[String[1]]            $scan_observer_user     = undef,
  Optional[Sensitive[String[1]]] $scan_observer_password = undef,
) {
  if $admin_password =~ NotUndef and $admin_password.unwrap =~ /\A\s|\s\z/ {
    fail('openvas: admin_password cannot start or end with whitespace, because gvm-tools strips it and the login would never work')
  }

  # One without the other used to create nothing and say nothing, leaving
  # whatever reads reports with a user gvmd has never heard of.
  if ($scan_observer_user =~ Undef) != ($scan_observer_password =~ Undef) {
    fail('openvas: set scan_observer_user and scan_observer_password together, or neither')
  }

  contain openvas::install
  contain openvas::config
  contain openvas::service
  contain openvas::scans

  Class['openvas::install']
  -> Class['openvas::config']
  -> Class['openvas::service']
  -> Class['openvas::scans']
}
