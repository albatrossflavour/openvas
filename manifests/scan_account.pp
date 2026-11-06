# @summary The account the scanner logs in as, on a node it scans.
#
# Include this on the nodes you scan, not on the scanner. On Linux it creates
# the account with the scan key's public half. On Windows it creates a local
# administrator with the scan password. It reads the same Hiera keys as the
# scanner, so the login and Windows password are set once for both.
#
# Skip it if you already manage this account some other way, or Puppet will
# report a duplicate `user` resource.
#
# @param ssh_public_key
#   The whole line from the `.pub` file, such as `ssh-rsa AAAA... openvas-scan`.
#   Needed on Linux.
# @param login
#   The account name. Defaults to `openvas::scan_login`, then `openvas`.
# @param windows_password
#   The account's password. Defaults to `openvas::scan_windows_password`.
#   Needed on Windows.
#
# @example Linux and Windows nodes alike
#   include openvas::scan_account
#
# @example Hiera, common to the scanner and the nodes
#   openvas::scan_account::ssh_public_key: "ssh-rsa AAAAB3Nza... openvas-scan"
#   openvas::scan_windows_password: ENC[PKCS7,...]
class openvas::scan_account (
  Optional[Pattern[/\A(ssh|ecdsa|sk)-\S+ \S+/]] $ssh_public_key = undef,
  Optional[String[1]] $login = undef,
  Optional[Sensitive[String[1]]] $windows_password = undef,
) {
  # The scanner's keys, so one Hiera value serves the scanner and the nodes.
  $_login = $login.lest || { lookup('openvas::scan_login', String[1], 'first', 'openvas') }
  $_password = $windows_password.lest || { lookup('openvas::scan_windows_password', Optional[Sensitive[String[1]]], 'first', undef) }

  if $facts['os']['family'] == 'windows' {
    if $_password =~ Undef {
      fail('openvas::scan_account needs openvas::scan_windows_password on Windows')
    }

    user { $_login:
      ensure   => present,
      password => $_password,
      groups   => ['Administrators'],
    }
  } else {
    if $ssh_public_key =~ Undef {
      fail('openvas::scan_account needs openvas::scan_account::ssh_public_key on Linux')
    }

    $key = $ssh_public_key.split(' ')

    user { $_login:
      ensure     => present,
      managehome => true,
      shell      => '/bin/bash',
    }

    ssh_authorized_key { "${_login}-scan":
      ensure  => present,
      user    => $_login,
      type    => $key[0],
      key     => $key[1],
      require => User[$_login],
    }
  }
}
