require 'spec_helper'

describe 'homelab_compute::default' do
  platform 'debian', '13'
  step_into :homelab_compute_agent, :homelab_base_verified_release
  automatic_attributes['hostname'] = 'compute1'
  automatic_attributes['ipaddress'] = '10.60.0.41'
  default_attributes['homelab_compute'] = {
    'agent' => { 'version' => '0.4.0' },
    'node_labels' => { 'topology.kubernetes.io/zone' => 'pve' },
  }

  it 'installs the firmware and vTPM packages UEFI domains need' do
    expect(chef_run).to install_package(%w(libvirt-daemon-system qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools))
  end

  it 'runs the system libvirt daemon the agent drives' do
    expect(chef_run).to enable_service('libvirtd')
    expect(chef_run).to start_service('libvirtd')
  end

  it 'installs the agent from the pinned Ayatori release' do
    expect(chef_run.remote_file('/var/cache/homelab-cinc/ayatori-compute-agent_0.4.0_linux_amd64.tar.gz').source)
      .to eq(['https://git.ddupan.top/panxiao81/ayatori/releases/download/v0.4.0/ayatori-compute-agent_0.4.0_linux_amd64.tar.gz'])
  end

  it 'configures the agent in the schema it parses strictly' do
    config = JSON.parse(chef_run.file('/etc/ayatori/compute-agent.yaml').content)
    expect(config).to eq(
      'nodeName' => 'compute1', 'credentialsDir' => '/etc/ayatori/compute-agent',
      'stateDir' => '/var/lib/ayatori/compute-agent', 'hostReservedMemory' => '2Gi',
      'nodeLabels' => { 'topology.kubernetes.io/zone' => 'pve' }, 'metricsAddress' => '10.60.0.41:9642'
    )
  end

  it 'leaves the credentials to the deployer and the agent' do
    expect(chef_run).to create_directory('/etc/ayatori/compute-agent').with(mode: '0700')
    expect(chef_run.find_resources(:file).map(&:path).grep(%r{\A/etc/ayatori/compute-agent/})).to be_empty
  end

  it 'starts the agent only once the node has joined' do
    expect(chef_run.systemd_unit('ayatori-compute-agent.service').content)
      .to include('ConditionPathExists=/etc/ayatori/compute-agent/bootstrap-kubeconfig')
    expect(chef_run).not_to start_service('ayatori-compute-agent')
  end

  it 'refuses role labels' do
    klass = Chef::Resource.resource_for_node(:homelab_compute_agent, chef_run.node)
    expect { klass.new('default').node_labels('node-role.kubernetes.io/compute' => '') }
      .to raise_error(Chef::Exceptions::ValidationFailed)
  end

  it 'refuses a wildcard metrics address' do
    klass = Chef::Resource.resource_for_node(:homelab_compute_agent, chef_run.node)
    expect { klass.new('default').metrics_address(':9642') }.to raise_error(Chef::Exceptions::ValidationFailed)
  end

  context 'without an agent version' do
    default_attributes['homelab_compute'] = { 'agent' => { 'version' => nil } }

    it 'fails instead of guessing a release' do
      expect { chef_run }.to raise_error(RuntimeError, /agent.version must be set/)
    end
  end
end
