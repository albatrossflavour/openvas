# @summary Docker, the compose plugin, and the install directory.
# @api private
class openvas::install {
  assert_private()

  # Docker's own apt repository carries the compose plugin, so the class that
  # adds the repository has to go first.
  if $openvas::manage_docker {
    include docker
    Class['docker'] -> Package['docker-compose-plugin']
  }

  package { 'docker-compose-plugin':
    ensure => installed,
  }

  file { $openvas::install_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0750',
  }
}
