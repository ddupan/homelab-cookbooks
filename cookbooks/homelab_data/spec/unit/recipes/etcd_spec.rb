require 'spec_helper'

describe 'homelab_data::etcd' do
  platform 'ubuntu', '24.04'
  automatic_attributes['hostname'] = 'etcd-pve3'
  default_attributes['homelab_data'] = {
    'etcd' => { 'members' => { 'etcd-pve1' => '10.60.0.20', 'etcd-pve2' => '10.60.0.21', 'etcd-pve3' => '10.60.0.22' } },
  }

  it 'joins the existing cluster at its own address' do
    is_expected.to render_file('/etc/homelab-etcd/etcd.yml')
      .with_content('name: "etcd-pve3"')
      .with_content('listen-client-urls: https://10.60.0.22:2379')
      .with_content('initial-cluster: "etcd-pve1=https://10.60.0.20:2380,etcd-pve2=https://10.60.0.21:2380,etcd-pve3=https://10.60.0.22:2380"')
      .with_content('initial-cluster-state: existing')
  end

  it 'never restarts etcd, and starts it only with data or after member add' do
    unit = chef_run.systemd_unit('homelab-etcd.service')
    expect(unit.action).to eq(%i(create enable))
    expect(chef_run.service('homelab-etcd').action).to eq([:start])
    expect(unit.content).to include('ConditionPathExists=|/var/lib/homelab-etcd/member')
      .and include('ConditionPathExists=|/etc/homelab-etcd/join')
    expect(chef_run.file('/etc/homelab-etcd/etcd.yml')).not_to notify('systemd_unit[homelab-etcd.service]')
  end

  it 'renews certificates on the node through its SPIFFE identity' do
    config = JSON.parse(chef_run.file('/etc/homelab-etcd/cert.json').content)
    expect(config).to include('name' => 'etcd-pve3', 'address' => '10.60.0.22', 'bao_role' => 'homelab-etcd-member')
    is_expected.to enable_systemd_unit('homelab-etcd-cert.timer')
  end

  context 'on a node that is not in the member list' do
    automatic_attributes['hostname'] = 'etcd-pve9'

    it 'refuses to converge' do
      expect { chef_run }.to raise_error(RuntimeError, /must list this node/)
    end
  end
end
