# @summary The compose file. Versioned here so the stack only changes through a module release.
# @api private
class openvas::config {
  assert_private()

  file { "${openvas::install_dir}/compose.yaml":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('openvas/compose.yaml.epp', {
      'feed_release'     => $openvas::feed_release,
      'web_bind_address' => $openvas::web_bind_address,
    }),
  }
}
