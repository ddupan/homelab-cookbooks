require 'spec_helper'

describe 'homelab_ayatori::default' do
  platform 'ubuntu', '24.04'
  step_into :homelab_ayatori_k0s, :homelab_ayatori_container
  image = 'zot.lab.ddupan.top/panxiao81/ayatori-manager@sha256:' + 'a' * 64

  default_attributes['homelab_ayatori'] = {
    'environment' => 'dev', 'release' => 'v0.3.0', 'image' => image,
    'postgresql_instance' => { 'name' => 'pg', 'host' => 'pg.lab', 'hostaddr' => '10.0.0.1', 'port' => 5432 }
  }
  automatic_attributes['ipaddress'] = '10.0.0.11'

  before do
    stub_command(%r{^/usr/local/bin/k0s kubectl}).and_return(true)
    stub_command(/^podman image exists/).and_return(true)
    stub_command(/^mountpoint/).and_return(true)
    stub_command(/^test -f/).and_return(true)
  end

  it 'runs kube-controller-manager with the certificate controllers' do
    is_expected.to render_file('/etc/k0s/k0s.yaml')
      .with_content('controllers: namespace,csrsigning,csrcleaner,tokencleaner')
      .with_content('address: 10.0.0.11')
  end

  it 'lets kube-state-metrics read LoadBalancer status for the endpoint health metrics' do
    is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content('network.ayatori.ddupan.top]')
  end

  it 'manages every identity through client-credentials, as root with file capabilities only' do
    is_expected.to render_file('/etc/containers/systemd/client-credentials.container').with_content { |c|
      expect(c).to include('PodmanArgs=--entrypoint=/client-credentials', 'User=0',
                           'AddCapability=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER',
                           '--identity=flux-kustomize-controller=/identities/flux-kustomize-controller')
    }
  end

  it 'mounts each identity read-only into its container' do
    is_expected.to render_file('/etc/containers/systemd/ayatori-manager.container').with_content { |c|
      expect(c).to include("Image=#{image}", 'User=65532', 'Volume=/etc/ayatori-control-plane/ayatori-controller:/identity:ro',
                           'Environment=KUBECONFIG=/identity/kubeconfig')
      expect(c).not_to include('--loadbalancer-address-pool')
    }
  end

  context 'with LoadBalancer enabled' do
    default_attributes['homelab_ayatori']['loadbalancer'] = {
      'address_pool' => '10.62.1.0/24',
      'dns' => { 'url' => 'http://192.168.10.127:8053', 'zone' => 'dev-lb.lab.ddupan.top' },
    }
    default_attributes['homelab_ayatori']['gitops'] = {
      'url' => 'https://git.ddupan.top/panxiao81/homelab-infra.git', 'path' => './clusters/ayatori-dev'
    }

    it 'passes the pool and the DNS zone to the manager, syncs the LB credentials and lets gitops declare LBs' do
      is_expected.to render_file('/etc/containers/systemd/ayatori-manager.container')
        .with_content('--loadbalancer-address-pool=10.62.1.0/24')
        .with_content('--loadbalancer-dns-zone=dev-lb.lab.ddupan.top')
      is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content('POWERDNS_API_KEY_PATH: "k8s/powerdns"')
      is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content('path: ./deploy/flux/loadbalancer')
      is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml')
        .with_content('resources: [loadbalancerhosts, loadbalancers, backends]')
    end
  end

  it 'leaves node agents and agent convergence off until the environment switches' do
    is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content { |c|
      expect(c).not_to include('deploy/flux/nodes')
    }
  end

  context 'when the LB hosts converge themselves (ADR-0022)' do
    default_attributes['homelab_ayatori']['node_agents'] = true
    default_attributes['homelab_ayatori']['loadbalancer'] = { 'address_pool' => '10.62.1.0/24', 'agent_convergence' => true }

    it 'syncs the node agent permissions and lets the manager only aggregate' do
      is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content('path: ./deploy/flux/nodes')
      is_expected.to render_file('/etc/containers/systemd/ayatori-manager.container')
        .with_content('--loadbalancer-agent-convergence')
    end
  end

  context 'with agent convergence but no node agents' do
    default_attributes['homelab_ayatori']['loadbalancer'] = { 'address_pool' => '10.62.1.0/24', 'agent_convergence' => true }

    it('fails') { expect { chef_run }.to raise_error(RuntimeError, /needs homelab_ayatori.node_agents/) }
  end

  context 'without hostaddr' do
    default_attributes['homelab_ayatori'] = {
      'environment' => 'dev', 'release' => 'v0.3.0', 'image' => image,
      'postgresql_instance' => { 'name' => 'pg', 'host' => 'pg.lab', 'port' => 5432 }
    }

    it 'renders an empty address so the Instance resolves host' do
      is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content('POSTGRESQL_HOSTADDR: ""')
    end
  end

  context 'with an image pinned only by tag' do
    default_attributes['homelab_ayatori']['image'] = 'zot.lab.ddupan.top/panxiao81/ayatori-manager:v0.3.0'

    it('fails') { expect { chef_run }.to raise_error(Chef::Exceptions::ValidationFailed, /pinned by digest/) }
  end

  context 'without the environment' do
    default_attributes['homelab_ayatori']['environment'] = nil

    it('fails') { expect { chef_run }.to raise_error(RuntimeError, /environment must be set/) }
  end
end
