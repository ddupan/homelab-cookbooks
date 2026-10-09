require 'spec_helper'

describe 'homelab_base::default' do
  platform 'ubuntu', '24.04'
  step_into :homelab_base_ca_trust, :homelab_base_ssh_ca_trust, :homelab_base_node_exporter
  automatic_attributes['ipaddress'] = '10.60.0.20'

  it 'binds node_exporter to the node address, never all interfaces' do
    is_expected.to render_file('/etc/default/prometheus-node-exporter')
      .with_content('--web.listen-address=10.60.0.20:9100')
  end

  it 'writes the listen address before installing the package' do
    resources = chef_run.resource_collection.all_resources.map(&:to_s)
    expect(resources.index('file[/etc/default/prometheus-node-exporter]'))
      .to be < resources.index('apt_package[prometheus-node-exporter]')
  end

  it 'rejects a wildcard listen address' do
    klass = Chef::Resource.resource_for_node(:homelab_base_node_exporter, chef_run.node)
    expect { klass.new('0.0.0.0:9100').listen }.to raise_error(Chef::Exceptions::ValidationFailed)
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
end
