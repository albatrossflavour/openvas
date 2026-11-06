# @summary Makes a node ready for credentialed scans from the openvas scanner.
#
# Include this on the nodes you scan; the scanner itself takes `openvas`. It
# creates the account the scanner logs in as. On Linux that is an account with
# the scan key's public half, and on Windows a local administrator with the
# scan password. It reads the scanner's own Hiera keys for the login and the
# Windows password, so those are set once for both.
#
# Safe to include everywhere before the Hiera values exist: without them it
# warns and changes nothing, and starts working once they are set.
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
# @example In a profile every scanned node gets
#   include openvas::target
#
# @example Hiera, common to the scanner and the nodes
#   openvas::target::ssh_public_key: "ssh-rsa AAAAB3Nza... openvas-scan"
#   openvas::scan_windows_password: ENC[PKCS7,...]
class openvas::target (
  Optional[Pattern[/\A(ssh|ecdsa|sk)-\S+ \S+/]] $ssh_public_key = undef,
  Optional[String[1]] $login = undef,
  Boolean $manage_user = true,
  Optional[Sensitive[String[1]]] $windows_password = undef,
) {
  # The scanner's keys, so one Hiera value serves the scanner and the nodes.
  $_login = $login.lest || { lookup('openvas::scan_login', String[1], 'first', 'openvas') }
  $_password = $windows_password.lest || { lookup('openvas::scan_windows_password', Optional[Sensitive[String[1]]], 'first', undef) }

  if $facts['os']['family'] == 'windows' {
    if $manage_user {
      if $_password =~ Undef {
        warning('openvas::target: openvas::scan_windows_password is not set, so no scan account is created')
      } else {
        user { $_login:
          ensure   => present,
          password => $_password,
          groups   => ['Administrators'],
        }
      }
    }
  } elsif $ssh_public_key =~ Undef {
    warning('openvas::target: openvas::target::ssh_public_key is not set, so no scan account is created')
  } else {
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
