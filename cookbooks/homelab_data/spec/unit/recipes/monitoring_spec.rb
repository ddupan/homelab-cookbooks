require 'spec_helper'

describe 'homelab_data::monitoring' do
  platform 'ubuntu', '24.04'
  automatic_attributes['ipaddress'] = '10.60.0.20'

  def config
    JSON.parse(chef_run.file('/etc/homelab-data-monitoring/config.json').content)
  end

  it 'checks etcd only by default' do
    expect(config['certificates'].map { |c| c['name'] })
      .to eq(%w(etcd-server etcd-peer etcd-admin etcd-gateway etcd-ca))
    expect(config['repository']).to be false
  end

  context 'on the PostgreSQL replica and the repository' do
    default_attributes['homelab_data'] = { 'postgresql_prod' => true, 'pgbackrest_repository' => true }

    it 'adds their certificates and backup check' do
      expect(config['certificates'].map { |c| c['name'] }).to include('pg-prod-server', 'pg-prod-etcd', 'pg-prod-ca')
      expect(config['repository']).to be true
    end
  end

  it 'exposes the metrics on the node address only' do
    expect(chef_run.systemd_unit('homelab-data-exporter.service').content)
      .to include('--web.listen-address=10.60.0.20:9109')
  end

  it 'removes the GitHub node_exporter the Ansible play left' do
    expect(chef_run).to delete_directory('/opt/homelab-data-monitoring/node_exporter-1.9.1.linux-amd64')
    expect(chef_run).to delete_file('/opt/homelab-data-monitoring/node_exporter.tar.gz')
  end
end
