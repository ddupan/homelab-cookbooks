require 'spec_helper'

describe 'homelab_loadbalancer::default' do
  platform 'debian', '13'
  step_into :homelab_loadbalancer_haproxy, :homelab_loadbalancer_dataplaneapi, :homelab_loadbalancer_agent,
            :homelab_loadbalancer_vip_guard, :homelab_base_verified_release
  automatic_attributes['hostname'] = 'lb1'
  automatic_attributes['ipaddress'] = '10.60.0.31'
  default_attributes['homelab_loadbalancer'] = {
    'agent' => { 'version' => '0.3.0' },
    'bgp' => { 'local_as' => 65101, 'neighbors' => { '10.60.0.1' => 65000 }, 'vip_pool' => '10.62.1.0/24' },
  }

  it 'moves host services off the wildcard address' do
    expect(chef_run.node['homelab_base']['listen_address']).to eq('10.60.0.31')
  end

  it 'rejects VIP traffic that would reach a wildcard listener' do
    is_expected.to render_file('/etc/ayatori-lb/vip-guard.nft')
      .with_content('ip daddr 10.62.1.0/24 socket wildcard 1 reject')
    is_expected.to enable_systemd_unit('ayatori-vip-guard.service')
  end

  it 'trusts the HAProxy repository by its fetched keyring, with no gpg import on the host' do
    expect(chef_run).to create_remote_file('/etc/apt/keyrings/haproxy.gpg')
    expect(chef_run).to add_apt_repository('haproxy').with(key: nil, signed_by: '/etc/apt/keyrings/haproxy.gpg')
    expect(chef_run).not_to install_apt_package('gpg')
  end

  # homelab-infra's converge play recreates the dir holding file_cache_path on every
  # run, so anything cached there is re-downloaded and the apply is never changed=0.
  it 'downloads nothing into the per-run Chef cache' do
    paths = chef_run.resource_collection.all_resources
                    .select { |r| r.declared_type == :remote_file }.map(&:path)
    expect(paths).to include('/var/cache/homelab-cinc/checksums.txt')
    expect(paths.grep(/\A#{Regexp.escape(Chef::Config[:file_cache_path])}/)).to be_empty
  end

  it 'never renders the file dataplaneapi owns, only creates it when missing' do
    expect(chef_run).to create_file_if_missing('/etc/haproxy/haproxy.cfg')
    expect(chef_run).not_to create_file('/etc/haproxy/haproxy.cfg')
  end

  it 'keeps global, defaults and resolvers in the Chef-owned base config' do
    is_expected.to render_file('/etc/haproxy/base.cfg')
      .with_content('server-state-file /var/lib/haproxy/server-state')
      .with_content('load-server-state-from-file global')
      .with_content('resolvers lan')
      .with_content('stats socket /run/haproxy/agent.sock mode 660 group haproxy level operator')
  end

  it 'loads both files and saves server state before every reload' do
    is_expected.to render_file('/etc/systemd/system/haproxy.service.d/ayatori.conf').with_content { |unit|
      expect(unit).to include('-f /etc/haproxy/base.cfg -f /etc/haproxy/haproxy.cfg')
      expect(unit.index('show servers state')).to be < unit.index('kill -USR2')
    }
  end

  it 'validates dataplaneapi transactions with the base config loaded first' do
    is_expected.to render_file('/etc/dataplaneapi/dataplaneapi.yml')
      .with_content(%r{validate_files_before:\n\s+- /etc/haproxy/base.cfg})
      .with_content('reload_cmd: systemctl reload haproxy.service')
  end

  it 'never prints the dataplaneapi config in a diff' do
    expect(chef_run.file('/etc/dataplaneapi/dataplaneapi.yml').sensitive).to be true
  end

  it 'installs the agent from the pinned Ayatori release' do
    expect(chef_run.remote_file('/var/cache/homelab-cinc/ayatori-lb-agent_0.3.0_linux_amd64.tar.gz').source)
      .to eq(['https://git.ddupan.top/panxiao81/ayatori/releases/download/v0.3.0/ayatori-lb-agent_0.3.0_linux_amd64.tar.gz'])
  end

  it 'configures the agent in the schema it parses strictly' do
    config = JSON.parse(chef_run.file('/etc/ayatori/lb-agent.yaml').content)
    expect(config).to eq(
      'asn' => 65101, 'routerID' => '10.60.0.31',
      'neighbors' => [{ 'address' => '10.60.0.1', 'asn' => 65000 }],
      'vipPool' => '10.62.1.0/24', 'haproxySocket' => '/run/haproxy/agent.sock',
      'metricsAddress' => '10.60.0.31:9641',
      'nodeName' => 'lb1', 'credentialsDir' => '/etc/ayatori/lb-agent',
      'dataPlane' => { 'url' => 'http://127.0.0.1:5556', 'username' => 'lb-agent',
                       'passwordFile' => '/etc/ayatori/lb-agent-dataplane.password' }
    )
  end

  it 'restarts the agent the ordinary way while graceful restart is off' do
    expect(chef_run.service('ayatori-lb-agent').restart_command).to be_nil
  end

  context 'with graceful restart' do
    default_attributes['homelab_loadbalancer']['agent'] = { 'version' => '0.4.0', 'graceful_restart_time' => '30s' }

    it 'configures it and restarts the agent with SIGKILL so the router keeps its paths' do
      expect(JSON.parse(chef_run.file('/etc/ayatori/lb-agent.yaml').content)).to include('gracefulRestartTime' => '30s')
      expect(chef_run.service('ayatori-lb-agent').restart_command)
        .to eq('systemctl kill -s SIGKILL ayatori-lb-agent || systemctl restart ayatori-lb-agent')
    end
  end

  it 'gives the agent only lo management and the read-only HAProxy socket' do
    unit = chef_run.systemd_unit('ayatori-lb-agent.service').content
    expect(unit).to include('User=ayatori-lb-agent').and include('SupplementaryGroups=haproxy')
    expect(unit).to include('CapabilityBoundingSet=CAP_NET_ADMIN')
    expect(unit).not_to include('BindsTo=')
  end

  context 'with the local password file in place' do
    before do
      allow(::File).to receive(:exist?).and_call_original
      allow(::File).to receive(:exist?).with('/etc/ayatori/lb-agent-dataplane.password').and_return(true)
      allow(::File).to receive(:read).and_call_original
      allow(::File).to receive(:read).with('/etc/ayatori/lb-agent-dataplane.password').and_return("s3cret\n")
    end

    it 'gives the agent its credentials directory and nothing else writable' do
      expect(chef_run).to create_directory('/etc/ayatori/lb-agent').with(owner: 'ayatori-lb-agent', mode: '0700')
      expect(chef_run.systemd_unit('ayatori-lb-agent.service').content)
        .to include("PrivateTmp=yes\nReadWritePaths=/etc/ayatori/lb-agent\nExecStart=")
    end

    it 'generates the local password once, readable by the agent only' do
      expect(chef_run).to create_file_if_missing('/etc/ayatori/lb-agent-dataplane.password')
        .with(owner: 'ayatori-lb-agent', mode: '0400', sensitive: true)
    end

    # A why-run creates nothing: the first run on a new host must still render.
    it 'renders before the password file exists, as in the first why-run' do
      allow(::File).to receive(:exist?).with('/etc/ayatori/lb-agent-dataplane.password').and_return(false)
      is_expected.to render_file('/etc/dataplaneapi/dataplaneapi.yml').with_content("password: '(created on apply)'")
    end

    it 'creates the password file in the agent resource, before the config that names it' do
      names = chef_run.resource_collection.all_resources.map(&:to_s)
      expect(names.index('file[/etc/ayatori/lb-agent-dataplane.password]'))
        .to be < names.index('file[/etc/ayatori/lb-agent.yaml]')
    end

    # ADR-0022: the control plane never connects, so nothing listens on the node address.
    it 'listens on loopback only, for the agent alone' do
      is_expected.to render_file('/etc/dataplaneapi/dataplaneapi.yml').with_content { |config|
        expect(config).to include("scheme: [http]\n  host: 127.0.0.1\n  port: 5556\n  user:\n")
        expect(config).to include("user:\n    - name: lb-agent\n      password: 's3cret'\n      insecure: true\n  transaction:")
        expect(config).not_to include('tls')
      }
    end
  end

  it 'removes the remote listener\'s certificate, its renewal and the client CA' do
    expect(chef_run).to stop_systemd_unit('ayatori-lb-cert.timer')
    expect(chef_run).to delete_systemd_unit('ayatori-lb-cert.timer')
    expect(chef_run).to delete_systemd_unit('ayatori-lb-cert.service')
    expect(chef_run).to delete_file('/usr/local/sbin/ayatori-lb-cert')
    expect(chef_run).to delete_file('/etc/ayatori-lb/client-ca.pem')
    expect(chef_run).to delete_directory('/etc/ayatori-lb/tls').with(recursive: true)
    expect(chef_run).to delete_directory('/var/lib/ayatori-lb-acme').with(recursive: true)
  end

  it 'removes the gobgpd speaker it replaces' do
    expect(chef_run).to delete_file('/etc/systemd/system/gobgpd.service')
    expect(chef_run).to delete_directory('/etc/gobgpd')
  end

  it 'refuses a wildcard status and metrics address' do
    klass = Chef::Resource.resource_for_node(:homelab_loadbalancer_agent, chef_run.node)
    expect { klass.new('default').metrics_address('0.0.0.0:9641') }.to raise_error(Chef::Exceptions::ValidationFailed)
  end
end
