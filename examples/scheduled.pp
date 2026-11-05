# Scan every OS family weekly, with credentials, and reach the web UI from the
# network. In practice, keep the secrets in eyaml and these values in Hiera.
class { 'openvas':
  web_bind_address      => '0.0.0.0',
  scan_schedule_enabled => true,
  scan_ssh_private_key  => Sensitive('-----BEGIN OPENSSH PRIVATE KEY-----...'),
  scan_windows_password => Sensitive('a local administrator password'),
}
