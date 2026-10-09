require 'spec_helper'

describe 'homelab_loadbalancer::default' do
  platform 'debian', '13'
  step_into :homelab_loadbalancer_haproxy, :homelab_loadbalancer_dataplaneapi, :homelab_loadbalancer_gobgpd,
            :homelab_loadbalancer_server_cert
  automatic_attributes['hostname'] = 'lb1'
  automatic_attributes['ipaddress'] = '10.60.0.31'
  default_attributes['homelab_loadbalancer'] = {
    'environment' => 'prod',
    'dataplaneapi' => { 'password_hash' => '$6$salt$hash' },
    'bgp' => { 'local_as' => 65101, 'neighbors' => { '10.60.0.1' => 65000 }, 'vip_pool' => '10.62.1.0/24' },
  }

  it 'never renders the file dataplaneapi owns, only creates it when missing' do
    expect(chef_run).to create_file_if_missing('/etc/haproxy/haproxy.cfg')
    expect(chef_run).not_to create_file('/etc/haproxy/haproxy.cfg')
  end

  it 'keeps global, defaults and resolvers in the Chef-owned base config' do
    is_expected.to render_file('/etc/haproxy/base.cfg')
      .with_content('server-state-file /var/lib/haproxy/server-state')
      .with_content('load-server-state-from-file global')
      .with_content('resolvers lan')
  end

  it 'loads both files and saves server state before every reload' do
    is_expected.to render_file('/etc/systemd/system/haproxy.service.d/ayatori.conf').with_content { |unit|
      expect(unit).to include('-f /etc/haproxy/base.cfg -f /etc/haproxy/haproxy.cfg')
      expect(unit.index('show servers state')).to be < unit.index('kill -USR2')
    }
  end

  it 'trusts only this environment\'s client CA' do
    expect(chef_run.remote_file('/etc/ayatori-lb/client-ca.pem').source)
      .to eq(['https://bao.ad.ddupan.top:8200/v1/pki-loadbalancer-prod/ca/pem'])
  end

  it 'validates dataplaneapi transactions with the base config loaded first' do
    is_expected.to render_file('/etc/dataplaneapi/dataplaneapi.yml')
      .with_content(%r{validate_files_before:\n\s+- /etc/haproxy/base.cfg})
      .with_content('tls_ca: /etc/ayatori-lb/client-ca.pem')
  end

  it 'applies the VIP-only policy globally, where gobgpd honours it' do
    is_expected.to render_file('/etc/gobgpd/gobgpd.toml').with_content { |toml|
      expect(toml).to include('[global.apply-policy.config]')
      expect(toml).not_to include('neighbors.apply-policy')
      expect(toml).to include('ip-prefix = "10.62.1.0/24"').and include('masklength-range = "32..32"')
    }
  end

  it "answers http-01 on the node address only, for the node's lab name" do
    is_expected.to render_file('/usr/local/sbin/ayatori-lb-cert')
      .with_content("--http.address '10.60.0.31:80'")
      .with_content("--domains 'lb1.lab.ddupan.top'")
      .with_content('https://bao.ad.ddupan.top:8200/v1/pki/acme/directory')
  end

  it 'issues only when no certificate has been deployed yet' do
    expect(chef_run.execute('/usr/local/sbin/ayatori-lb-cert').creates).to eq('/etc/ayatori-lb/tls/server.crt')
  end

  it 'restarts both APIs after a renewal, since they read the certificate at start' do
    is_expected.to render_file('/usr/local/sbin/ayatori-lb-cert-deploy')
      .with_content('systemctl try-restart dataplaneapi.service gobgpd.service')
  end

  it 'stops the speaker whenever HAProxy stops' do
    expect(chef_run.systemd_unit('gobgpd.service').content).to include('BindsTo=haproxy.service')
  end

  it 'refuses a plaintext Basic password' do
    klass = Chef::Resource.resource_for_node(:homelab_loadbalancer_dataplaneapi, chef_run.node)
    expect { klass.new('default').password_hash('plaintext') }.to raise_error(Chef::Exceptions::ValidationFailed)
  end

  it 'refuses a wildcard gRPC listen address' do
    klass = Chef::Resource.resource_for_node(:homelab_loadbalancer_gobgpd, chef_run.node)
    expect { klass.new('default').api_listen('0.0.0.0:50051') }.to raise_error(Chef::Exceptions::ValidationFailed)
  end

  context 'without an environment' do
    default_attributes['homelab_loadbalancer'] = { 'environment' => nil }

    it 'fails instead of trusting some CA' do
      expect { chef_run }.to raise_error(RuntimeError, /environment must be set/)
    end
  end
end
