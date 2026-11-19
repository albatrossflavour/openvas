# frozen_string_literal: true

require 'spec_helper'

describe 'openvas' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }
      let(:compose) { '/opt/greenbone-community-container/compose.yaml' }
      let(:pre_condition) do
        <<~PP
          function node_encrypt::secret($data) { $data }
        PP
      end

      context 'with a bare include' do
        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_class('docker') }
        it { is_expected.to contain_class('openvas::install') }
        it { is_expected.to contain_class('openvas::service') }
        it { is_expected.to contain_class('openvas::scans') }
        it { is_expected.to contain_file('/opt/greenbone-community-container').with('ensure' => 'directory', 'mode' => '0750') }
        it { is_expected.to contain_package('docker-compose-plugin') }
        it { is_expected.to contain_file(compose).with_content(%r{- 127\.0\.0\.1:443:443$}) }
        it { is_expected.to contain_file(compose).with_content(%r{FEED_RELEASE: "24\.10"}) }
        it { is_expected.to contain_file(compose).with_content(%r{^name: greenbone-community-edition$}) }
        it { is_expected.to contain_file(compose).with_content(%r{CC-BY-SA-4\.0}) }
        it { is_expected.to contain_file(compose).that_notifies('Exec[greenbone-compose-up]') }
        it { is_expected.to contain_exec('greenbone-compose-up').with_refreshonly(true) }
        it { is_expected.to contain_systemd__unit_file('greenbone-stack.service').with('active' => true, 'enable' => true) }

        # A failed first `compose up` won't refire, as the file is already in
        # place: the unit is what retries it, so it must not sit behind the exec
        # in a way that skips it. It's ordered after, and failure there is
        # retried on the next run through the unit's active => true.
        it { is_expected.to contain_systemd__unit_file('greenbone-stack.service').with_content(%r{ExecStart=/usr/bin/docker compose up -d --remove-orphans}) }

        it { is_expected.to contain_systemd__timer('greenbone-feed-update.timer').with_active(true) }
        it { is_expected.to contain_systemd__timer('greenbone-feed-update.timer').with_timer_content(%r{^OnCalendar=\*-\*-\* 05:53:00$}) }
        it { is_expected.to contain_systemd__timer('greenbone-image-update.timer').with_active(true) }
        it { is_expected.to contain_logrotate__rule('greenbone-openvas').with_copytruncate(true) }

        # The self-scan comes from this subnet, so it has to be fixed rather than
        # whatever Docker picks.
        it 'puts the compose network on a fixed subnet' do
          compose_yaml = YAML.safe_load(catalogue.resource('File', compose)[:content], aliases: true)
          expect(compose_yaml.dig('networks', 'default', 'ipam', 'config')).to eq([{ 'subnet' => '172.29.0.0/24' }])
        end
      end

      context 'with the compose network moved' do
        let(:params) { { 'compose_subnet' => '10.250.3.0/24' } }

        it { is_expected.to contain_file(compose).with_content(%r{^        - subnet: 10\.250\.3\.0/24$}) }
      end

      ['172.29.0.1', 'fd00::/64', 'nonsense'].each do |subnet|
        context "with compose_subnet #{subnet}, which is not an IPv4 subnet" do
          let(:params) { { 'compose_subnet' => subnet } }

          it { is_expected.to compile.and_raise_error(%r{compose_subnet}) }
        end
      end

      context 'with the feed refresh moved to working hours' do
        let(:params) { { 'feed_update_schedule' => 'Mon..Fri *-*-* 10:00:00' } }

        it { is_expected.to contain_systemd__timer('greenbone-feed-update.timer').with_timer_content(%r{^OnCalendar=Mon\.\.Fri \*-\*-\* 10:00:00$}) }
      end

      context 'with a feed refresh schedule that would add lines to the unit' do
        let(:params) { { 'feed_update_schedule' => "daily\nExecStartPre=/bin/true" } }

        it { is_expected.to compile.and_raise_error(%r{feed_update_schedule}) }
      end

      context 'with manage_docker false' do
        let(:params) { { 'manage_docker' => false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_class('docker') }
      end

      ['10.0.0.0/8', '::1'].each do |address|
        context "with web_bind_address #{address}, which compose can't publish" do
          let(:params) { { 'web_bind_address' => address } }

          it { is_expected.to compile.and_raise_error(%r{web_bind_address}) }
        end
      end

      context 'with an install_dir the wrapper could not quote' do
        let(:params) { { 'install_dir' => '/opt/green bone' } }

        it { is_expected.to compile.and_raise_error(%r{install_dir}) }
      end

      context 'when only the compose file changes' do
        it { is_expected.not_to contain_class('openvas::config').that_notifies('Class[openvas::service]') }
        it { is_expected.to contain_class('openvas::config').that_comes_before('Class[openvas::service]') }
      end

      context 'with a web_bind_address that is not an address' do
        let(:params) { { 'web_bind_address' => 'nonsense' } }

        it { is_expected.to compile.and_raise_error(%r{web_bind_address}) }
      end
    end
  end
end
