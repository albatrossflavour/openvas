# @summary The compose file. Versioned here so the stack only changes through a module release.
# @api private
class openvas::config {
  assert_private()

  if ($openvas::web_certificate =~ Undef) != ($openvas::web_key =~ Undef) {
    fail('openvas::web_certificate and openvas::web_key go together: set both or neither')
  }
  $web_certs = $openvas::web_certificate =~ NotUndef

  file { "${openvas::install_dir}/compose.yaml":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('openvas/compose.yaml.epp', {
      'feed_release'     => $openvas::feed_release,
      'web_bind_address' => $openvas::web_bind_address,
      'compose_subnet'   => $openvas::compose_subnet,
      'install_dir'      => $openvas::install_dir,
      'web_certs'        => $web_certs,
    }),
  }

  # The web UI's certificate and key, copied so the container sees them at the
  # paths its nginx config names and so a renewed agent certificate reaches it on
  # the next run. Root only: the container's nginx runs as root.
  if $web_certs {
    file { "${openvas::install_dir}/certs":
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0700',
    }
    file { "${openvas::install_dir}/certs/server.cert.pem":
      ensure => file,
      owner  => 'root',
      group  => 'root',
      mode   => '0644',
      source => "file://${openvas::web_certificate}",
    }
    file { "${openvas::install_dir}/certs/server.key":
      ensure    => file,
      owner     => 'root',
      group     => 'root',
      mode      => '0600',
      source    => "file://${openvas::web_key}",
      show_diff => false,
    }
  }
}
