# frozen_string_literal: true

require 'spec_helper'
require 'json'

describe 'openvas' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }
      let(:dir) { '/opt/greenbone-community-container' }
      let(:rows) do
        [
          { 'certname' => 'a.example.com', 'facts.networking.ip' => '192.0.2.1', 'facts.os.family' => 'Debian' },
          { 'certname' => 'b.example.com', 'facts.networking.ip' => '192.0.2.2', 'facts.os.family' => 'RedHat' },
          { 'certname' => 'w.example.com', 'facts.networking.ip' => '192.0.2.3', 'facts.os.family' => 'windows' },
        ]
      end
      let(:puppetdb_answer) { rows.inspect }
      let(:pre_condition) do
        <<~PP
          function node_encrypt::secret($data) { $data }
          function puppetdb_query(String $query) { #{puppetdb_answer} }
        PP
      end
      let(:state) { JSON.parse(catalogue.resource('file', "#{dir}/scan-state.json")[:content]) }

      context 'with a bare include' do
        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_exec('greenbone-reconcile').with_command('/usr/local/sbin/greenbone-reconcile apply') }
        it { is_expected.to contain_exec('greenbone-admin-generate').with_creates("#{dir}/gvm-admin.conf") }
        it { is_expected.not_to contain_file("#{dir}/gvm-admin.conf") }
        it { is_expected.to contain_file('/usr/local/sbin/greenbone-reconcile').with_mode('0750') }
        it { is_expected.to contain_file("#{dir}/scan-state.json").with_mode('0600') }

        it 'keeps the password out of the catalogue' do
          is_expected.to contain_exec('greenbone-admin-password').with('command' => '/usr/local/sbin/greenbone-reconcile set-password',
                                                                       'unless' => '/usr/local/sbin/greenbone-reconcile auth')
        end

        it 'has no schedules and no purge, and no min_hosts' do
          expect(state['schedules']).to eq([])
          expect(state['purge']).to be(false)
          expect(state).not_to have_key('min_hosts')
          expect(state['tasks'].map { |t| t['schedule'] }).to eq([nil, nil, nil])
        end

        it 'builds a target and task per family, with no credentials' do
          expect(state['credentials']).to eq([])
          expect(state['tasks'].map { |t| t['name'] }).to eq(['Puppet: Debian', 'Puppet: RedHat', 'Puppet: Windows'])
          expect(state['targets'].map { |t| t['ssh_credential'] }).to eq([nil, nil, nil])
          expect(state['targets'].map { |t| t['smb_credential'] }).to eq([nil, nil, nil])
        end
      end

      context 'with a supplied admin password' do
        let(:params) { { 'admin_password' => sensitive('s3cret') } }

        it { is_expected.to contain_file("#{dir}/gvm-admin.conf").with('mode' => '0600', 'owner' => 'root') }
        it { is_expected.not_to contain_exec('greenbone-admin-generate') }
        it { is_expected.to contain_exec('greenbone-admin-password').with_command('/usr/local/sbin/greenbone-reconcile set-password') }

        it 'escapes % for gvm-tools' do
          params['admin_password'] = sensitive('a%b')
          is_expected.to contain_file("#{dir}/gvm-admin.conf").with_content(%r{^password = a%%b$})
        end
      end

      [
        ['a Hash', '{}'],
        ['an empty Array', '[]'],
        ['rows with no address', "[{'certname' => 'a', 'facts.networking.ip' => undef, 'facts.os.family' => 'Debian'}]"],
      ].each do |desc, answer|
        context "when PuppetDB answers with #{desc}" do
          let(:puppetdb_answer) { answer }

          it { is_expected.to compile.with_all_deps }
          it { is_expected.not_to contain_exec('greenbone-reconcile') }
          it { is_expected.not_to contain_file("#{dir}/scan-state.json") }
          it { is_expected.to contain_exec('greenbone-admin-generate') }
          it { is_expected.to contain_exec('greenbone-admin-password') }
        end
      end

      context 'when puppetdb_query is not available' do
        let(:pre_condition) { 'function node_encrypt::secret($data) { $data }' }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_exec('greenbone-reconcile') }
        it { is_expected.to contain_class('docker') }
      end

      context 'when puppetdb_query raises' do
        let(:pre_condition) do
          <<~PP
            function node_encrypt::secret($data) { $data }
            function puppetdb_query(String $query) { fail('PuppetDB is down') }
          PP
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_exec('greenbone-reconcile') }
      end

      context 'with only an SSH key' do
        let(:params) { { 'scan_ssh_private_key' => sensitive('KEY') } }

        it 'has one credential, referenced by Linux targets only' do
          expect(state['credentials'].map { |c| c['name'] }).to eq(['Puppet: SSH openvas'])
          expect(state['targets'].map { |t| t['ssh_credential'] }).to eq(['Puppet: SSH openvas', 'Puppet: SSH openvas', nil])
          expect(state['targets'].map { |t| t['smb_credential'] }).to eq([nil, nil, nil])
        end
      end

      context 'with an excluded certname' do
        let(:params) { { 'scan_exclude' => ['b.example.com'] } }

        it 'leaves it out' do
          expect(state['tasks'].map { |t| t['name'] }).to eq(['Puppet: Debian', 'Puppet: Windows'])
        end
      end

      context 'with a shared address' do
        let(:rows) do
          [
            { 'certname' => 'a.example.com', 'facts.networking.ip' => '192.0.2.1', 'facts.os.family' => 'Debian' },
            { 'certname' => 'b.example.com', 'facts.networking.ip' => '192.0.2.1', 'facts.os.family' => 'Debian' },
            { 'certname' => 'c.example.com', 'facts.networking.ip' => '192.0.2.2', 'facts.os.family' => 'Debian' },
          ]
        end

        it 'leaves it out of the host map' do
          map = JSON.parse(catalogue.resource('file', "#{dir}/scan-hosts.json")[:content])
          expect(map).to eq('192.0.2.2' => 'c.example.com')
        end
      end

      # Reconciler digests hash these. A change here recreates objects in gvmd on
      # every existing install, so it has to be deliberate.
      context 'with everything set, pinning the state shape' do
        let(:params) do
          {
            'admin_password' => sensitive('s3cret'),
            'scan_ssh_private_key' => sensitive('KEY'),
            'scan_windows_password' => sensitive('PW'),
            'scan_purge' => true,
            'scan_schedule_enabled' => true,
            'scan_observer_user' => 'reader',
            'scan_observer_password' => sensitive('RO'),
          }
        end

        it 'keeps the Debian target' do
          expect(state['targets'][0]).to eq('name' => 'Puppet: Debian', 'hosts' => ['192.0.2.1'], 'alive_test' => 'Consider Alive',
                                            'ssh_credential' => 'Puppet: SSH openvas', 'ssh_port' => 22, 'smb_credential' => nil)
        end

        it 'keeps the Windows target' do
          expect(state['targets'][2]).to eq('name' => 'Puppet: Windows', 'hosts' => ['192.0.2.3'], 'alive_test' => 'Consider Alive',
                                            'ssh_credential' => nil, 'ssh_port' => 22, 'smb_credential' => 'Puppet: SMB openvas')
        end

        it 'keeps the task' do
          expect(state['tasks'][0]).to eq('name' => 'Puppet: Debian', 'target' => 'Puppet: Debian', 'schedule' => 'Puppet: weekly Debian',
                                          'max_hosts' => 20, 'max_checks' => 4, 'observers' => ['reader'])
        end

        it 'keeps the credentials' do
          expect(state['credentials']).to eq([
                                               { 'name' => 'Puppet: SSH openvas', 'type' => 'usk', 'login' => 'openvas', 'private_key' => 'KEY' },
                                               { 'name' => 'Puppet: SMB openvas', 'type' => 'up', 'login' => 'openvas', 'password' => 'PW' },
                                             ])
        end

        it 'keeps the schedule' do
          expect(state['schedules'][0]).to eq(
            'name' => 'Puppet: weekly Debian', 'timezone' => 'UTC',
            'icalendar' => "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//puppet//greenbone//EN\nBEGIN:VEVENT\nDTSTART:20260912T180000Z\n" \
                           "DURATION:PT0S\nRRULE:FREQ=WEEKLY\nUID:puppet-greenbone-debian\nDTSTAMP:20260915T000000Z\nEND:VEVENT\nEND:VCALENDAR"
          )
        end

        it 'creates the observer' do
          expect(state['users']).to eq([{ 'name' => 'reader', 'role' => 'Observer', 'password' => 'RO' }])
        end
      end
    end
  end
end
