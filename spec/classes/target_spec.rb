# frozen_string_literal: true

require 'spec_helper'

describe 'openvas::target' do
  let(:pub) { 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 openvas-scan' }
  let(:logs) { [] }

  before(:each) do
    Puppet::Util::Log.newdestination(Puppet::Test::LogCollector.new(logs))
  end

  def warnings
    # Only this module's: the spec harness's own Hiera setup warns as well.
    logs.select { |l| l.level == :warning && l.message.include?('openvas::') }.map(&:message)
  end

  context 'on Linux' do
    let(:facts) { { 'os' => { 'family' => 'Debian', 'name' => 'Ubuntu' }, 'kernel' => 'Linux' } }

    context 'with a public key' do
      let(:params) { { 'ssh_public_key' => pub } }

      it { is_expected.to compile.with_all_deps }
      it { is_expected.to contain_user('openvas').with(ensure: 'present', managehome: true, shell: '/bin/bash') }

      it 'splits the .pub line into type and key' do
        is_expected.to contain_ssh_authorized_key('openvas-scan')
          .with(ensure: 'present', user: 'openvas', type: 'ssh-rsa', key: 'AAAAB3NzaC1yc2EAAAADAQABAAABAQC7')
          .that_requires('User[openvas]')
      end
    end

    context 'with a different login' do
      let(:params) { { 'ssh_public_key' => pub, 'login' => 'scanner' } }

      it { is_expected.to contain_user('scanner') }
      it { is_expected.to contain_ssh_authorized_key('scanner-scan').with_user('scanner') }
    end

    context 'with an existing account' do
      let(:params) { { 'ssh_public_key' => pub, 'login' => 'svc_scan', 'manage_user' => false } }

      it { is_expected.to compile.with_all_deps }
      it { is_expected.not_to contain_user('svc_scan') }
      it { is_expected.to contain_ssh_authorized_key('svc_scan-scan').with(user: 'svc_scan', key: 'AAAAB3NzaC1yc2EAAAADAQABAAABAQC7') }
    end

    context 'without a public key' do
      it 'compiles, changes nothing, and says why' do
        is_expected.to compile.with_all_deps
        is_expected.to have_resource_count(0)
        expect(warnings).to include(%r{openvas::target::ssh_public_key is not set})
      end
    end

    context 'with a private key by mistake' do
      let(:params) { { 'ssh_public_key' => '-----BEGIN OPENSSH PRIVATE KEY-----' } }

      it { is_expected.to compile.and_raise_error(%r{ssh_public_key}) }
    end
  end

  context 'on Windows' do
    let(:facts) { { 'os' => { 'family' => 'windows', 'name' => 'windows' }, 'kernel' => 'windows' } }

    context 'with the scan password' do
      let(:params) { { 'windows_password' => sensitive('s3cret') } }

      # No compile matcher: its autorequire pass calls the Windows ADSI user
      # provider, which can't run off Windows. Compiling is proven by the next
      # example, which reads the catalogue.
      it 'makes a local administrator with the password' do
        is_expected.to contain_user('openvas').with(ensure: 'present', groups: ['Administrators'], password: sensitive('s3cret'))
      end

      it { is_expected.not_to contain_ssh_authorized_key('openvas-scan') }
    end

    context 'with the login and password only in Hiera' do
      let(:hiera_config) { 'spec/fixtures/hiera/hiera.yaml' }

      it 'uses the scanner keys' do
        is_expected.to contain_user('hieralogin').with_password(sensitive('from-hiera'))
      end
    end

    context 'with an existing account' do
      let(:params) { { 'login' => 'svc_scan', 'manage_user' => false } }

      it 'changes nothing, and needs no password' do
        is_expected.to have_resource_count(0)
        expect(warnings).to be_empty
      end
    end

    context 'without the scan password' do
      it 'changes nothing, and says why' do
        is_expected.to have_resource_count(0)
        expect(warnings).to include(%r{openvas::scan_windows_password is not set})
      end
    end
  end
end
