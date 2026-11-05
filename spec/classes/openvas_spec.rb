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
        it { is_expected.to contain_package('docker-compose-plugin') }
        it { is_expected.to contain_file(compose).with_content(%r{- 127\.0\.0\.1:443:443$}) }
        it { is_expected.to contain_file(compose).with_content(%r{FEED_RELEASE: "24\.10"}) }
        it { is_expected.to contain_file(compose).with_content(%r{^name: greenbone-community-edition$}) }
        it { is_expected.to contain_file(compose).that_notifies('Exec[greenbone-compose-up]') }
        it { is_expected.to contain_exec('greenbone-compose-up').with_refreshonly(true) }
        it { is_expected.to contain_systemd__unit_file('greenbone-stack.service').with('active' => true, 'enable' => true) }

        # A failed first `compose up` won't refire, as the file is already in
        # place: the unit is what retries it, so it must not sit behind the exec
        # in a way that skips it. It's ordered after, and failure there is
        # retried on the next run through the unit's active => true.
        it { is_expected.to contain_systemd__unit_file('greenbone-stack.service').with_content(%r{ExecStart=/usr/bin/docker compose up -d --remove-orphans}) }

        it { is_expected.to contain_systemd__timer('greenbone-feed-update.timer').with_active(true) }
        it { is_expected.to contain_systemd__timer('greenbone-image-update.timer').with_active(true) }
        it { is_expected.to contain_logrotate__rule('greenbone-openvas').with_copytruncate(true) }
      end

      context 'with manage_docker false' do
        let(:params) { { 'manage_docker' => false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_class('docker') }
      end

      context 'with a web_bind_address that is not an address' do
        let(:params) { { 'web_bind_address' => 'nonsense' } }

        it { is_expected.to compile.and_raise_error(%r{web_bind_address}) }
      end
    end
  end
end
