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
    stub_command(/^systemctl show -p SubState/).and_return(false)
  end

  it 'runs kube-controller-manager with the certificate controllers' do
    is_expected.to render_file('/etc/k0s/k0s.yaml')
      .with_content('controllers: namespace,csrsigning,csrcleaner,tokencleaner')
      .with_content('address: 10.0.0.11')
  end

  it 'accepts only client certificates and service accounts without OIDC' do
    is_expected.to render_file('/etc/k0s/k0s.yaml').with_content { |c| expect(c).not_to include('authentication-config') }
    is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content { |c| expect(c).not_to include('oidc-admins') }
    is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content { |c| expect(c).not_to include('ayatori-login') }
    is_expected.to delete_file('/etc/ayatori-apiserver/authentication.yaml')
  end

  context 'with OIDC' do
    default_attributes['homelab_ayatori']['oidc'] = {
      'issuer' => 'https://sso.example', 'audiences' => %w(ayatori-dev), 'admin_groups' => %w(platform-admins)
    }

    before do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with('/var/lib/k0s/pki/ca.crt')
                                   .and_return("-----BEGIN CERTIFICATE-----\nk0s\n-----END CERTIFICATE-----\n")
    end

    it 'makes the admin group cluster-admin' do
      is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content { |c|
        binding = YAML.load_stream(c).compact.find { |d| d['metadata']['name'] == 'oidc-admins' }
        expect(binding['roleRef']['name']).to eq('cluster-admin')
        expect(binding['subjects']).to eq([{ 'kind' => 'Group', 'apiGroup' => 'rbac.authorization.k8s.io',
                                             'name' => 'oidc:platform-admins' }])
      }
    end

    it 'points the apiserver at a structured authentication config it can read' do
      is_expected.to render_file('/etc/k0s/k0s.yaml')
        .with_content("extraArgs:\n          authentication-config: /etc/ayatori-apiserver/authentication.yaml")
      is_expected.to create_file('/etc/ayatori-apiserver/authentication.yaml').with(mode: '0644')
      is_expected.to create_directory('/etc/ayatori-apiserver').with(mode: '0755')
    end

    it 'lets anonymous requests read only the login discovery ConfigMap' do
      config = YAML.safe_load(chef_run.file('/etc/ayatori-apiserver/authentication.yaml').content)
      discovery = { 'path' => '/api/v1/namespaces/kube-public/configmaps/ayatori-login' }
      expect(config['anonymous']).to eq('enabled' => true, 'conditions' => [discovery])
      is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content { |c|
        docs = YAML.load_stream(c).compact.select { |d| d['metadata']['name'] == 'ayatori-login' }
        expect(docs.map { |d| d['metadata']['namespace'] }.uniq).to eq(%w(kube-public))
        login = docs.find { |d| d['kind'] == 'ConfigMap' }
        expect(login['data']).to eq('issuer' => 'https://sso.example', 'clientID' => 'ayatori-dev',
                                    'ca.crt' => "-----BEGIN CERTIFICATE-----\nk0s\n-----END CERTIFICATE-----\n")
        role = docs.find { |d| d['kind'] == 'Role' }
        expect(role['rules']).to eq([{ 'apiGroups' => [''], 'resources' => %w(configmaps),
                                       'resourceNames' => %w(ayatori-login), 'verbs' => %w(get) }])
        binding = docs.find { |d| d['kind'] == 'RoleBinding' }
        expect(binding['subjects']).to eq([{ 'kind' => 'Group', 'apiGroup' => 'rbac.authorization.k8s.io',
                                             'name' => 'system:unauthenticated' }])
      }
    end

    it 'maps iam-login users and groups under the oidc: prefix for this environment only' do
      config = YAML.safe_load(chef_run.file('/etc/ayatori-apiserver/authentication.yaml').content)
      jwt = config['jwt'].first
      expect(jwt['issuer']).to eq('url' => 'https://sso.example', 'audiences' => %w(ayatori-dev),
                                  'audienceMatchPolicy' => 'MatchAny')
      expect(jwt['claimMappings']).to eq('username' => { 'claim' => 'preferred_username', 'prefix' => 'oidc:' },
                                         'groups' => { 'claim' => 'groups', 'prefix' => 'oidc:' })
    end
  end

  context 'with OIDC and SPIFFE' do
    default_attributes['homelab_ayatori']['oidc'] = { 'issuer' => 'https://sso.example', 'audiences' => %w(ayatori-dev) }
    default_attributes['homelab_ayatori']['spiffe_issuer'] = 'https://spire-oidc.example'

    before do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with('/var/lib/k0s/pki/ca.crt')
                                   .and_return("-----BEGIN CERTIFICATE-----\nk0s\n-----END CERTIFICATE-----\n")
    end

    it 'accepts JWT-SVIDs for the same audiences with the SPIFFE ID as the username' do
      config = YAML.safe_load(chef_run.file('/etc/ayatori-apiserver/authentication.yaml').content)
      expect(config['jwt'].map { |j| j['issuer']['url'] }).to eq(%w(https://sso.example https://spire-oidc.example))
      spiffe = config['jwt'].last
      expect(spiffe['issuer']).to eq('url' => 'https://spire-oidc.example', 'audiences' => %w(ayatori-dev),
                                     'audienceMatchPolicy' => 'MatchAny')
      expect(spiffe['claimMappings']).to eq('username' => { 'claim' => 'sub', 'prefix' => '' })
      expect(config['anonymous']['enabled']).to be true
    end
  end

  context 'with SPIFFE but no OIDC' do
    default_attributes['homelab_ayatori']['spiffe_issuer'] = 'https://spire-oidc.example'

    it 'fails: the audiences come from oidc' do
      expect { chef_run }.to raise_error(RuntimeError, /spiffe_issuer needs oidc/)
    end
  end

  context 'with OIDC but no audience' do
    default_attributes['homelab_ayatori']['oidc'] = { 'issuer' => 'https://sso.example' }

    it 'fails instead of accepting tokens for any client' do
      expect { chef_run }.to raise_error(RuntimeError, /oidc needs issuer and audiences/)
    end
  end

  it 'keeps a declared hostaddr on the Instance' do
    is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content { |c|
      expect(c).to include('POSTGRESQL_HOSTADDR: "10.0.0.1"')
      expect(c).not_to include('/spec/endpoint/hostaddr')
    }
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

  it 'runs no ayatori-api unless enabled' do
    is_expected.not_to render_file('/etc/containers/systemd/ayatori-api.container')
    is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content { |c| expect(c).not_to include('APIService') }
  end

  context 'with ayatori-api' do
    default_attributes['homelab_ayatori']['ayatori_api'] = true
    serving = '/etc/ayatori-control-plane/ayatori-api-serving'

    before do
      stub_command(/^openssl x509 -checkend/).and_return(false)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("#{serving}/tls.crt").and_return('SERVING-CERT')
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with("#{serving}/tls.crt").and_return(true)
    end

    it 'self-signs the serving certificate for the service name, renewing it before it expires' do
      is_expected.to run_execute('ayatori-api serving certificate').with(
        command: a_string_including('-subj /CN=ayatori-api.ayatori-system.svc',
                                    'subjectAltName=DNS:ayatori-api.ayatori-system.svc', "-out #{serving}/tls.crt")
      )
      is_expected.to create_directory(serving).with(owner: 65_532, mode: '0700')
    end

    it 'registers the APIService through an ExternalName Service on loopback, pinning that certificate' do
      is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content { |c|
        docs = YAML.load_stream(c).compact
        service = docs.find { |d| d['kind'] == 'Service' && d['metadata']['name'] == 'ayatori-api' }
        expect(service['spec']).to eq('type' => 'ExternalName', 'externalName' => '127.0.0.1', 'ports' => [{ 'port' => 9445 }])
        api = docs.find { |d| d['kind'] == 'APIService' }
        expect(api['metadata']['name']).to eq('v1alpha1.subresources.ayatori.ddupan.top')
        expect(api['spec']['caBundle'].unpack1('m0')).to eq('SERVING-CERT')
        expect(api['spec']['service']).to eq('namespace' => 'ayatori-system', 'name' => 'ayatori-api', 'port' => 9445)
      }
    end

    context 'before the certificate exists (why-run on first enabling)' do
      before do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with("#{serving}/tls.crt").and_return(false)
      end

      it 'renders an empty caBundle instead of failing, which trusts no backend' do
        is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content { |c|
          api = YAML.load_stream(c).compact.find { |d| d['kind'] == 'APIService' }
          expect(api['spec']['caBundle']).to eq('')
        }
      end
    end

    it 'runs it from the manager image with its own identity and OpenBao role' do
      is_expected.to render_file('/etc/containers/systemd/ayatori-api.container').with_content { |c|
        expect(c).to include("Image=#{image}", 'PodmanArgs=--entrypoint=/ayatori-api', 'User=65532',
                             'Volume=/etc/ayatori-control-plane/ayatori-api:/identity:ro', "Volume=#{serving}:/serving:ro",
                             '--listen=127.0.0.1:9445', '--openbao-auth-role=ayatori-dev-api',
                             '--openbao-service-account-name=api-openbao-login',
                             '--database-credential-prefix=ayatori/dev/applications')
      }
      is_expected.to render_file('/etc/containers/systemd/client-credentials.container')
        .with_content('--identity=ayatori-api=/identities/ayatori-api')
    end
  end

  context 'with LoadBalancer enabled' do
    default_attributes['homelab_ayatori']['loadbalancer'] = {
      'address_pool' => '10.62.1.0/24',
      'dns' => { 'url' => 'http://192.168.10.127:8053', 'zone' => 'dev-lb.lab.ddupan.top' },
    }
    default_attributes['homelab_ayatori']['gitops'] = {
      'url' => 'https://github.com/ddupan/homelab-infra.git', 'path' => './clusters/ayatori-dev'
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
    default_attributes['homelab_ayatori']['postgresql_instance']['hostaddr'] = nil

    it 'removes the field from the Instance so Flux does not apply a null' do
      is_expected.to render_file('/var/lib/ayatori-deploy/bootstrap.yaml').with_content('path: /spec/endpoint/hostaddr')
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
