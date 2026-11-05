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
# @param web_bind_address
#   IPv4 host address the web UI binds to, on ports 443 and 9392.
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
# @param scan_purge
#   Remove every object in gvmd this module did not create, reports included.
# @param scan_schedule_enabled
#   Scan each OS family weekly. When false, targets and tasks exist but nothing
#   starts on its own.
# @param scan_exclude
#   Certnames to leave out of the scan scope.
# @param scan_schedule_starts
#   First run per OS family (UTC, iCalendar DTSTART), repeated weekly.
# @param scan_default_start
#   First run for any OS family not in `scan_schedule_starts`.
# @param scan_max_hosts
#   Hosts scanned concurrently per task.
# @param scan_max_checks
#   Tests run concurrently per host.
# @param scan_observer_user
#   Optional read-only gvmd user, for anything that pulls reports. It is created
#   with the Observer role and can see the managed tasks and their reports only.
# @param scan_observer_password
#   That user's password. The user is only created when both are set.
class openvas (
  Pattern[/\A\/[\w.\/-]+\z/]     $install_dir            = '/opt/greenbone-community-container',
  String[1]                      $feed_release           = '24.10',
  Stdlib::IP::Address::V4::Nosubnet $web_bind_address    = '127.0.0.1',
  Boolean                        $manage_docker          = true,
  Optional[Sensitive[String[1]]] $admin_password         = undef,
  Optional[Sensitive[String[1]]] $scan_ssh_private_key   = undef,
  Optional[Sensitive[String[1]]] $scan_windows_password  = undef,
  String[1]                      $scan_login             = 'openvas',
  Boolean                        $scan_purge             = false,
  Boolean                        $scan_schedule_enabled  = false,
  Array[String[1]]               $scan_exclude           = [],
  Hash[String[1], String[1]]     $scan_schedule_starts   = {
    'RedHat'  => '20260912T160000Z',
    'Debian'  => '20260912T180000Z',
    'windows' => '20260912T200000Z',
  },
  String[1]                      $scan_default_start     = '20260912T220000Z',
  Integer[1]                     $scan_max_hosts         = 20,
  Integer[1]                     $scan_max_checks        = 4,
  Optional[String[1]]            $scan_observer_user     = undef,
  Optional[Sensitive[String[1]]] $scan_observer_password = undef,
) {
  if $admin_password =~ NotUndef and $admin_password.unwrap =~ /\A\s|\s\z/ {
    fail('openvas: admin_password cannot start or end with whitespace, because gvm-tools strips it and the login would never work')
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
