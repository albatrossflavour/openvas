# @summary The account the scanner logs in as, on a node it scans.
#
# Include this on the nodes you scan, not on the scanner. On Linux it creates
# the account with the scan key's public half. On Windows it creates a local
# administrator with the scan password. It reads the same Hiera keys as the
# scanner, so the login and Windows password are set once for both.
#
# To use an account that already exists, set `manage_user` to false. On Linux
# the class then only adds the key, and on Windows it does nothing.
#
# @param ssh_public_key
#   The whole line from the `.pub` file, such as `ssh-rsa AAAA... openvas-scan`.
#   Needed on Linux.
# @param login
#   The account name. Defaults to `openvas::scan_login`, then `openvas`.
# @param manage_user
#   Whether to create the account. Set false for an account that already
#   exists or is managed elsewhere.
# @param windows_password
#   The account's password. Defaults to `openvas::scan_windows_password`.
#   Needed on Windows when `manage_user` is true.
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
  Boolean $manage_user = true,
  Optional[Sensitive[String[1]]] $windows_password = undef,
) {
  # The scanner's keys, so one Hiera value serves the scanner and the nodes.
  $_login = $login.lest || { lookup('openvas::scan_login', String[1], 'first', 'openvas') }
  $_password = $windows_password.lest || { lookup('openvas::scan_windows_password', Optional[Sensitive[String[1]]], 'first', undef) }

  if $facts['os']['family'] == 'windows' {
    if $manage_user and $_password =~ Undef {
      fail('openvas::scan_account needs openvas::scan_windows_password on Windows')
    }

    if $manage_user {
      user { $_login:
        ensure   => present,
        password => $_password,
        groups   => ['Administrators'],
      }
    }
  } else {
    if $ssh_public_key =~ Undef {
      fail('openvas::scan_account needs openvas::scan_account::ssh_public_key on Linux')
    }

    $key = $ssh_public_key.split(' ')

    if $manage_user {
      user { $_login:
        ensure     => present,
        managehome => true,
        shell      => '/bin/bash',
        before     => Ssh_authorized_key["${_login}-scan"],
      }
    }

    ssh_authorized_key { "${_login}-scan":
      ensure => present,
      user   => $_login,
      type   => $key[0],
      key    => $key[1],
    }
  }
}
