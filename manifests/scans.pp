# @summary
#   Puppet owns what Greenbone scans: one target and one task per OS family,
#   built from PuppetDB, plus the credentials they log in with and the admin
#   password it all runs as.
#
#   The desired state is rendered to a root-only JSON file and converged by
#   reconcile.gmp.py, a gvm-script run inside the gvm-tools container through
#   /usr/local/sbin/greenbone-reconcile. The exec only fires when the script's
#   check mode finds gvmd out of step, so a node joining or leaving PuppetDB
#   reaches the scan scope within one agent run on this host. Nothing changes
#   while a scan is running; the next run picks it up.
#
#   With the schedule and `scan_new_hosts` on, a certname that wasn't in scope
#   at the last apply also gets a one-off scan of its own, started by that
#   apply; see reconcile.gmp.py for how it is kept and retired.
#
#   Targets use "Consider Alive": discovery by ping drops every node whose
#   firewall drops ICMP, and scanning an explicit list from PuppetDB doesn't
#   need discovery at all.
#
#   Run `greenbone-reconcile plan` on the host to see what apply would do,
#   including while a scan is running.
#
# @api private
class openvas::scans {
  assert_private()

  $install_dir    = $openvas::install_dir
  $script         = "${install_dir}/reconcile.gmp.py"
  $state_file     = "${install_dir}/scan-state.json"
  $gmp_config     = "${install_dir}/gvm-admin.conf"
  $wrapper        = '/usr/local/sbin/greenbone-reconcile'
  $exec_path      = ['/usr/local/sbin', '/usr/bin', '/bin']
  $admin_password = $openvas::admin_password
  $login          = $openvas::scan_login

  file { $script:
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
    source => 'puppet:///modules/openvas/reconcile.gmp.py',
  }

  file { $wrapper:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0750',
    content => epp('openvas/greenbone-reconcile.epp', {
      'compose_file' => "${install_dir}/compose.yaml",
      'gmp_config'   => $gmp_config,
      'state_file'   => $state_file,
      'script'       => $script,
      'ready_marker' => "${install_dir}/.gvmd-ready",
    }),
  }

  # The stack's image creates `admin` with a known password, so this always
  # happens, whatever PuppetDB says. A generated password stays on the node and
  # never enters the catalogue.
  if $admin_password =~ Undef {
    exec { 'greenbone-admin-generate':
      command  => "pw=\"$(openssl rand -hex 24)\" && umask 077 && printf '[gmp]\\nusername = admin\\npassword = %s\\n' \"\$pw\" > ${gmp_config}",
      creates  => $gmp_config,
      path     => $exec_path,
      provider => 'shell',
    }
    $gmp_config_ref = Exec['greenbone-admin-generate']
  } else {
    file { $gmp_config:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0600',
      content => epp('openvas/gvm-tools.conf.epp', {
        'username' => 'admin',
        'password' => $admin_password,
      }).node_encrypt::secret,
    }
    $gmp_config_ref = File[$gmp_config]
  }

  # gvmd's own CLI is the only way to set a password gvmd no longer accepts, and
  # it takes the password as an argument, so while it runs the password is in
  # this host's process list. So it only runs when the password has stopped
  # logging in: the first run, or somebody changing it in the web UI.
  exec { 'greenbone-admin-password':
    command   => "${wrapper} set-password",
    unless    => "${wrapper} auth",
    path      => $exec_path,
    tries     => 3,
    try_sleep => 20,
    timeout   => 900,
    logoutput => true,
    require   => [File[$wrapper], $gmp_config_ref],
  }

  # Every active node's primary address and OS family. Anything but an Array
  # counts as no data, and a node missing either can't be placed in a target.
  $rows = openvas::puppetdb_rows('inventory[certname, facts.networking.ip, facts.os.family] { node_state = "active" }')
  $nodes = $rows ? {
    Array   => $rows.filter |$r| {
      $r['facts.networking.ip'] =~ String[1] and $r['facts.os.family'] =~ String[1] and !($r['certname'] in $openvas::scan_exclude)
    },
    default => [],
  }

  # A failed or empty PuppetDB answer must not become a target that scans
  # nothing, and with purge on it would also delete the real ones. Failing the
  # catalogue would stop everything else on this host converging, so leave the
  # scan scope alone and say why. The reconciler repeats this check on the file.
  if $nodes.empty {
    warning('openvas::scans: PuppetDB returned no hosts; scan targets left untouched')
  } else {
    $families = $nodes.group_by |$r| { $r['facts.os.family'] }

    $ssh_credential = "Puppet: SSH ${login}"
    # SMB can log in as its own account, such as a domain one, while SSH keeps
    # scan_login.
    $smb_login      = $openvas::scan_windows_login.lest || { $login }
    $smb_credential = "Puppet: SMB ${smb_login}"
    $has_ssh = $openvas::scan_ssh_private_key =~ NotUndef
    $has_smb = $openvas::scan_windows_password =~ NotUndef

    # Object names use the family as facts report it (RedHat, Debian), except
    # windows. `capitalize` would make RedHat "Redhat".
    $labels = $families.keys.reduce({}) |$memo, $family| {
      $memo + { $family => $family ? { 'windows' => 'Windows', default => $family } }
    }

    # Puppet reads `{` at the start of a lambda body as a block, not a hash, so
    # each entry is assigned and then returned.
    $all_schedules = $families.keys.sort.map |$family| {
      $start = pick($openvas::scan_schedule_starts[$family], $openvas::scan_default_start)
      $ical = [
        'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//puppet//greenbone//EN', 'BEGIN:VEVENT',
        "DTSTART:${start}", 'DURATION:PT0S', 'RRULE:FREQ=WEEKLY', "UID:puppet-greenbone-${family.downcase}",
        'DTSTAMP:20260915T000000Z', 'END:VEVENT', 'END:VCALENDAR',
      ].join("\n")
      $schedule = { 'name' => "Puppet: weekly ${labels[$family]}", 'timezone' => 'UTC', 'icalendar' => $ical }
      $schedule
    }
    $schedules = $openvas::scan_schedule_enabled ? {
      true    => $all_schedules,
      default => [],
    }

    # With scan_windows_smb_filter set, Windows splits in two: the active
    # Windows nodes the filter matches get the SMB credential, and the rest are
    # scanned without it, so a host outside the filter is never offered that
    # login. A PuppetDB failure here matches nothing, which scans every Windows
    # host unauthenticated rather than offering the login to all of them.
    $filter = $openvas::scan_windows_smb_filter
    if $filter =~ NotUndef {
      $answer = openvas::puppetdb_rows("inventory[certname] { node_state = \"active\" and facts.os.family = \"windows\" and (${filter}) }")
      $smb_members = $answer ? {
        Array   => $answer.filter |$r| { $r =~ Hash and $r['certname'] =~ String[1] }.map |$r| { $r['certname'] },
        default => [],
      }
    } else {
      $smb_members = []
    }

    # One target and task per group: one per family, or two for Windows when
    # the filter splits it.
    $groups = $families.keys.sort.reduce([]) |$memo, $family| {
      $label = $labels[$family]
      if $family == 'windows' and $filter =~ NotUndef {
        $members = $families[$family].filter |$r| { $r['certname'] in $smb_members }
        $rest = $families[$family].filter |$r| { !($r['certname'] in $smb_members) }
        $split = [
          { 'family' => $family, 'name' => "Puppet: ${label}", 'rows' => $members, 'smb' => true },
          { 'family' => $family, 'name' => "Puppet: ${label} unauthenticated", 'rows' => $rest, 'smb' => false },
        ]
        $memo + $split.filter |$g| { !$g['rows'].empty }
      } else {
        $memo + [{ 'family' => $family, 'name' => "Puppet: ${label}", 'rows' => $families[$family], 'smb' => $family == 'windows' }]
      }
    }

    $targets = $groups.map |$group| {
      $windows = $group['family'] == 'windows'
      $target = {
        'name'           => $group['name'],
        'hosts'          => $group['rows'].map |$r| { $r['facts.networking.ip'] }.unique.sort,
        # Sorted, so the state file doesn't churn. The reconciler lists these in
        # the target's comment, which is how it tells a new host from a moved one.
        'members'        => Hash($group['rows'].sort |$a, $b| { compare($a['certname'], $b['certname']) }.map |$r| {
          [$r['certname'], $r['facts.networking.ip']]
        }),
        'alive_test'     => 'Consider Alive',
        'ssh_credential' => if !$windows and $has_ssh { $ssh_credential } else { undef },
        'ssh_port'       => 22,
        'smb_credential' => if $group['smb'] and $has_smb { $smb_credential } else { undef },
      }
      $target
    }

    $ssh_credentials = if $has_ssh {
      [{ 'name' => $ssh_credential, 'type' => 'usk', 'login' => $login, 'private_key' => $openvas::scan_ssh_private_key.unwrap }]
    } else {
      []
    }
    $smb_credentials = if $has_smb {
      [{ 'name' => $smb_credential, 'type' => 'up', 'login' => $smb_login, 'password' => $openvas::scan_windows_password.unwrap }]
    } else {
      []
    }

    # admin reads everything already, so it never needs the Observer role.
    $observer = $openvas::scan_observer_user
    $users = if $observer =~ NotUndef and $observer != 'admin' and $openvas::scan_observer_password =~ NotUndef {
      [{ 'name' => $observer, 'role' => 'Observer', 'password' => $openvas::scan_observer_password.unwrap }]
    } else {
      []
    }

    $tasks = $groups.map |$group| {
      $task = {
        'name'       => $group['name'],
        'target'     => $group['name'],
        'schedule'   => if $openvas::scan_schedule_enabled { "Puppet: weekly ${labels[$group['family']]}" } else { undef },
        'max_hosts'  => $openvas::scan_max_hosts,
        'max_checks' => $openvas::scan_max_checks,
        'observers'  => $users.map |$u| { $u['name'] },
      }
      $task
    }

    $state = {
      'marker'        => 'managed-by=puppet',
      'purge'         => $openvas::scan_purge,
      'scanner'       => 'OpenVAS Default',
      'scan_config'   => 'Full and fast',
      'port_list'     => 'All IANA assigned TCP',
      'credentials'   => $ssh_credentials + $smb_credentials,
      'users'         => $users,
      'schedules'     => $schedules,
      'targets'       => $targets,
      'tasks'         => $tasks,
      'new_host_scan' => $openvas::scan_schedule_enabled and $openvas::scan_new_hosts,
    }

    # gvmd only knows the address it scanned and that address's reverse DNS name,
    # so anything pulling reports can name each host from this. An address more
    # than one certname claims can't be named honestly, so it's left out. No
    # secrets: addresses and certnames only.
    $host_map = $nodes.group_by |$r| { $r['facts.networking.ip'] }.reduce({}) |$memo, $entry| {
      $certnames = $entry[1].map |$r| { $r['certname'] }.unique
      $certnames.length ? {
        1       => $memo + { $entry[0] => $certnames[0] },
        default => $memo,
      }
    }
    # Sorted by address before rendering. PuppetDB returns rows in whatever order
    # it likes and to_json_pretty keeps insertion order, so the file would
    # otherwise rewrite itself with the same content on every run.
    $sorted_host_map = Hash($host_map.keys.sort.map |$ip| { [$ip, $host_map[$ip]] })
    $shared = $nodes.map |$r| { $r['facts.networking.ip'] }.unique.filter |$ip| { !($ip in $host_map) }
    unless $shared.empty {
      warning("openvas::scans: left out of the host map, claimed by more than one certname: ${shared.sort.join(', ')}")
    }

    file { "${install_dir}/scan-hosts.json":
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => stdlib::to_json_pretty($sorted_host_map),
    }

    # Holds the scan key and the Windows password, so root only and
    # node_encrypt'd in the catalogue.
    file { $state_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0600',
      content => stdlib::to_json_pretty($state).node_encrypt::secret,
    }

    exec { 'greenbone-reconcile':
      command   => "${wrapper} apply",
      unless    => "${wrapper} check",
      path      => $exec_path,
      timeout   => 1800,
      logoutput => true,
      require   => [File[$script, $wrapper, $state_file], Exec['greenbone-admin-password']],
    }
  }
}
