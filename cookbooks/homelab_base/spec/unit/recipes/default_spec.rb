require 'spec_helper'

describe 'homelab_base::default' do
  platform 'ubuntu', '24.04'
  step_into :homelab_base_ca_trust, :homelab_base_ssh_ca_trust, :homelab_base_node_exporter,
            :homelab_base_drift_check, :homelab_base_spire_agent,
            :homelab_base_spire_node_cert, :homelab_base_verified_release

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
    expect(service.content).to include('Environment=HOMELAB_CINC_MODE=drift')
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

  it 'attests the SPIRE agent with the ACME node certificate' do
    is_expected.to render_file('/etc/spire-agent/agent.conf')
      .with_content('NodeAttestor "x509pop"')
      .with_content('certificate_path = "/etc/spire-agent/node.crt"')
      .with_content('socket_path       = "/run/spire/agent-sockets/spire-agent.sock"')
  end

  it 'does not start the agent before enrollment' do
    is_expected.not_to start_service('spire-agent')
  end

  context 'with hostname etcd-pve1' do
    automatic_attributes['hostname'] = 'etcd-pve1'

    it 'requests the lab name, with a CN for the node alias selector' do
      is_expected.to render_file('/usr/local/sbin/spire-node-cert')
        .with_content("--domains 'etcd-pve1.lab.ddupan.top'")
        .with_content('--enable-cn')
    end
  end

  context 'with site endpoints from the node policy' do
    automatic_attributes['hostname'] = 'etcd-pve1'
    default_attributes['homelab_base'] = { 'bao' => 'https://bao.example:8200', 'domain' => 'site.example',
                                           'spire_server' => 'spire.example' }

    it 'uses them instead of the cookbook defaults' do
      is_expected.to render_file('/usr/local/sbin/spire-node-cert')
        .with_content('https://bao.example:8200/v1/pki-spire-nodes/roles/node/acme/directory')
        .with_content("--domains 'etcd-pve1.site.example'")
      expect(chef_run.remote_file('/etc/ssh/openbao_user_ca.pub').source)
        .to eq(['https://bao.example:8200/v1/ssh-client-signer/public_key'])
    end
  end

  it 'never carries an EAB credential itself, only the switch when one is passed in' do
    is_expected.to render_file('/usr/local/sbin/spire-node-cert')
      .with_content('${LEGO_EAB_KID:+--eab}')
      .with_content { |c| expect(c).not_to match(/eab\.(kid|hmac)/) }
  end

  it 'renews daily, only after enrollment' do
    expect(chef_run.systemd_unit('spire-node-cert.service').content)
      .to include('ConditionPathExists=/etc/spire-agent/node.crt')
    is_expected.to enable_systemd_unit('spire-node-cert.timer')
  end

  it 'deploys with the lego v5 hook variables' do
    is_expected.to render_file('/usr/local/sbin/spire-node-cert-deploy')
      .with_content('"$LEGO_HOOK_CERT_PATH"')
      .with_content('"$LEGO_HOOK_CERT_KEY_PATH"')
  end

  # The converge play recreates Cinc's cache with every run's staging dir: anything
  # downloaded there is re-downloaded each apply and missing in a fresh why-run.
  it 'never downloads into the per-run Cinc file cache' do
    paths = chef_run.resource_collection.grep(Chef::Resource::RemoteFile).map(&:path)
    expect(paths).not_to be_empty
    expect(paths).to all(satisfy { |p| !p.start_with?(Chef::Config[:file_cache_path]) })
  end

  it 'verifies release tarballs into the stable cache' do
    is_expected.to create_remote_file('/var/cache/homelab-cinc/lego_v5.3.1_linux_amd64.tar.gz')
    is_expected.to create_remote_file('/var/cache/homelab-cinc/spire-1.15.3-linux-amd64-musl.tar.gz')
  end
end
