# @summary Brings the stack up and keeps it up, current, and within its disk.
# @api private
class openvas::service {
  assert_private()

  $install_dir = $openvas::install_dir

  # `up -d` pulls any missing images, so the first run downloads the feed images
  # and takes a long time. Hence no timeout.
  exec { 'greenbone-compose-up':
    command     => 'docker compose up -d --remove-orphans',
    cwd         => $install_dir,
    path        => ['/usr/local/sbin', '/usr/local/bin', '/usr/sbin', '/usr/bin', '/sbin', '/bin'],
    timeout     => 0,
    refreshonly => true,
  }

  # Only some services carry a restart policy, so without this most of the stack
  # stays down after a reboot. The one-shot setup services run in dependency
  # order the same way. It also retries a first `compose up` that failed, which
  # the refresh-only exec above won't. Stopping this unit leaves the stack alone.
  systemd::unit_file { 'greenbone-stack.service':
    ensure  => present,
    enable  => true,
    active  => true,
    content => @("EOT"),
      [Unit]
      Description=Greenbone Community Edition stack
      Requires=docker.service
      After=docker.service network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      WorkingDirectory=${install_dir}
      ExecStart=/usr/bin/docker compose up -d --remove-orphans
      TimeoutStartSec=0

      [Install]
      WantedBy=multi-user.target
      | EOT
    require => Exec['greenbone-compose-up'],
  }

  # The scanner log lives in a named volume, so nothing on the host rotates it.
  # copytruncate because openvas keeps the file open. The volume path follows the
  # compose project name.
  logrotate::rule { 'greenbone-openvas':
    ensure       => present,
    path         => '/var/lib/docker/volumes/greenbone-community-edition_openvas_log_data_vol/_data/openvas.log',
    copytruncate => true,
    compress     => true,
    ifempty      => false,
    missingok    => true,
    maxsize      => '500M',
    rotate_every => 'day',
    rotate       => 7,
  }

  # The feed ships as data container images, so nothing changes until they are
  # pulled. `up -d` then recreates the data containers, which recopy their
  # volumes, and the one-shot setup steps run after them. Not Persistent:
  # catching up at boot would recopy the VT volume under a scanner still starting.
  $feed_services = 'vulnerability-tests notus-data scap-data cert-bund-data dfn-cert-data data-objects report-formats'

  systemd::timer { 'greenbone-feed-update.timer':
    ensure          => present,
    service_unit    => 'greenbone-feed-update.service',
    active          => true,
    enable          => true,
    timer_content   => @(EOT),
      [Timer]
      OnCalendar=*-*-* 05:53:00
      Unit=greenbone-feed-update.service

      [Install]
      WantedBy=timers.target
      | EOT
    service_content => @("EOT"),
      [Unit]
      Description=Pull Greenbone feed images and refresh the stack
      After=docker.service
      Requires=docker.service

      [Service]
      Type=oneshot
      WorkingDirectory=${install_dir}
      ExecCondition=/usr/local/sbin/greenbone-reconcile idle
      ExecStart=/usr/bin/docker compose pull --quiet ${feed_services}
      ExecStart=/usr/bin/docker compose up -d --remove-orphans
      ExecStartPost=/usr/bin/docker image prune -f
      | EOT
    require         => Exec['greenbone-compose-up'],
  }

  # The rest of the stack's images. Both timers carry an [Install] section:
  # without one the unit is static and only runs again after a reboot once
  # Puppet starts it. Both skip a run while a scan is going, because recreating
  # the scanner or the feed volumes under a live scan interrupts the report. The
  # prune drops the image each pull replaces.
  systemd::timer { 'greenbone-image-update.timer':
    ensure          => present,
    service_unit    => 'greenbone-image-update.service',
    active          => true,
    enable          => true,
    timer_content   => @(EOT),
      [Timer]
      OnCalendar=Wed *-*-* 03:17:00
      Unit=greenbone-image-update.service

      [Install]
      WantedBy=timers.target
      | EOT
    service_content => @("EOT"),
      [Unit]
      Description=Pull Greenbone stack images and recreate what changed
      After=docker.service
      Requires=docker.service

      [Service]
      Type=oneshot
      WorkingDirectory=${install_dir}
      ExecCondition=/usr/local/sbin/greenbone-reconcile idle
      ExecStart=/usr/bin/docker compose pull --quiet
      ExecStart=/usr/bin/docker compose up -d --remove-orphans
      ExecStartPost=/usr/bin/docker image prune -f
      | EOT
    require         => Exec['greenbone-compose-up'],
  }
}
