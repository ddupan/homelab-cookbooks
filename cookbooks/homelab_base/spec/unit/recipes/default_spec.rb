require 'spec_helper'

describe 'homelab_base::default' do
  platform 'ubuntu', '24.04'
  step_into :homelab_base_ca_trust, :homelab_base_ssh_ca_trust, :homelab_base_node_exporter,
            :homelab_base_drift_check

  it 'runs every node_exporter collector on a VM or bare metal' do
    is_expected.to render_file('/etc/default/prometheus-node-exporter')
      .with_content { |c| expect(c).not_to include('--no-collector') }
  end

  context 'in an LXC container' do
    automatic_attributes['virtualization'] = { 'system' => 'lxc', 'role' => 'guest' }

    it 'turns off collectors that only see host hardware' do
      is_expected.to render_file('/etc/default/prometheus-node-exporter')
        .with_content('--no-collector.hwmon')
        .with_content('--no-collector.diskstats')
    end
  end

  context 'on an LXC host' do
    automatic_attributes['virtualization'] = { 'system' => 'lxc', 'role' => 'host' }

    it 'keeps them: the host is where the hardware is' do
      is_expected.to render_file('/etc/default/prometheus-node-exporter')
        .with_content { |c| expect(c).not_to include('--no-collector') }
    end
  end

  it 'installs the internal CA and rebuilds the trust store only on change' do
    ca = chef_run.remote_file('/usr/local/share/ca-certificates/ddupan-internal-ca.crt')
    expect(ca).to notify('execute[update-ca-certificates]').to(:run).immediately
    expect(chef_run.execute('update-ca-certificates')).to do_nothing
  end

  it 'trusts the OpenBao SSH CA through a drop-in' do
    is_expected.to render_file('/etc/ssh/sshd_config.d/50-openbao-ca.conf')
      .with_content('TrustedUserCAKeys /etc/ssh/openbao_user_ca.pub')
  end

  it 'validates sshd config before any reload' do
    expect(chef_run.service('ssh').reload_command).to include('sshd -t &&')
  end

  it 'drift timer only why-runs the last applied policy' do
    service = chef_run.systemd_unit('homelab-cinc-drift.service')
    expect(service.content).to include('cinc-client -z --why-run')
    expect(service.content).to include('WorkingDirectory=/var/lib/homelab-cinc/policy')
    is_expected.to enable_systemd_unit('homelab-cinc-drift.timer')
  end

  it 'refreshes apt on a real converge' do
    is_expected.to periodic_apt_update('daily')
  end

  context 'in why-run' do
    before { Chef::Config[:why_run] = true }
    after { Chef::Config[:why_run] = false }

    it 'skips apt_update, which would otherwise report drift every day' do
      is_expected.not_to periodic_apt_update('daily')
    end
  end
end
