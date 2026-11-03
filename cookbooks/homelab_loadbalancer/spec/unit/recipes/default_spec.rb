require 'tmpdir'
require 'spec_helper'

describe 'homelab_loadbalancer::default' do
  platform 'debian', '13'
  step_into :homelab_loadbalancer_haproxy, :homelab_loadbalancer_dataplaneapi, :homelab_loadbalancer_agent,
            :homelab_loadbalancer_server_cert, :homelab_loadbalancer_vip_guard, :homelab_base_verified_release
  automatic_attributes['hostname'] = 'lb1'
  automatic_attributes['ipaddress'] = '10.60.0.31'
  default_attributes['homelab_loadbalancer'] = {
    'environment' => 'prod',
    'dataplaneapi' => { 'password_hash' => '$6$salt$hash' },
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
      .with_content('stats socket /run/haproxy/agent.sock mode 660 group haproxy level user')
  end

  it 'loads both files and saves server state before every reload' do
    is_expected.to render_file('/etc/systemd/system/haproxy.service.d/ayatori.conf').with_content { |unit|
      expect(unit).to include('-f /etc/haproxy/base.cfg -f /etc/haproxy/haproxy.cfg')
      expect(unit.index('show servers state')).to be < unit.index('kill -USR2')
    }
  end

  it 'trusts only this environment\'s client CA' do
    expect(chef_run.remote_file('/etc/ayatori-lb/client-ca.pem').source)
      .to eq(['https://bao.lab.ddupan.top:8200/v1/pki-loadbalancer-prod/ca/pem'])
  end

  it 'validates dataplaneapi transactions with the base config loaded first' do
    is_expected.to render_file('/etc/dataplaneapi/dataplaneapi.yml')
      .with_content(%r{validate_files_before:\n\s+- /etc/haproxy/base.cfg})
      .with_content('tls_ca: /etc/ayatori-lb/client-ca.pem')
      .with_content('reload_cmd: systemctl reload haproxy.service')
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
      'metricsAddress' => '10.60.0.31:9641'
    )
  end

  it 'gives the agent only lo management and the read-only HAProxy socket' do
    unit = chef_run.systemd_unit('ayatori-lb-agent.service').content
    expect(unit).to include('User=ayatori-lb-agent').and include('SupplementaryGroups=haproxy')
    expect(unit).to include('CapabilityBoundingSet=CAP_NET_ADMIN')
    expect(unit).not_to include('BindsTo=')
  end

  it 'removes the gobgpd speaker it replaces' do
    expect(chef_run).to delete_file('/etc/systemd/system/gobgpd.service')
    expect(chef_run).to delete_directory('/etc/gobgpd')
  end

  it "answers http-01 on the node address only, for the node's lab name" do
    is_expected.to render_file('/usr/local/sbin/ayatori-lb-cert')
      .with_content("--http.address '10.60.0.31:80'")
      .with_content("--domains 'lb1.lab.ddupan.top'")
      .with_content('https://bao.lab.ddupan.top:8200/v1/pki/acme/directory')
      .with_content("--key-type 'RSA2048'")
  end

  it 'issues only when no certificate has been deployed yet' do
    expect(chef_run.execute('/usr/local/sbin/ayatori-lb-cert').creates).to eq('/etc/ayatori-lb/tls/server.crt')
  end

  # Runs the rendered hook against a stub systemctl: on the first issue neither unit
  # exists yet (try-restart would exit 5 and fail the issue); on a renewal both do.
  {
    'skips units that are not installed yet (first issue)' => [[], []],
    'restarts dataplaneapi after a renewal, since it reads the certificate at start' =>
      [%w(dataplaneapi.service), %w(dataplaneapi.service)],
  }.each do |name, (installed, restarted)|
    it name do
      Dir.mktmpdir do |dir|
        hook = File.join(dir, 'hook')
        File.write(hook, chef_run.file('/usr/local/sbin/ayatori-lb-cert-deploy').content
          .gsub('/etc/ayatori-lb/tls/', "#{dir}/"))
        File.write(File.join(dir, 'systemctl'), <<~SH)
          #!/bin/sh
          case "$1" in
            cat) case " #{installed.join(' ')} " in *" $2 "*) exit 0 ;; *) exit 1 ;; esac ;;
            try-restart) echo "$2" >> #{dir}/restarted ;;
          esac
        SH
        File.write(File.join(dir, 'cert'), 'c')
        File.chmod(0o755, hook, File.join(dir, 'systemctl'))
        env = { 'PATH' => "#{dir}:/usr/bin:/bin", 'LEGO_HOOK_CERT_PATH' => File.join(dir, 'cert'),
                'LEGO_HOOK_CERT_KEY_PATH' => File.join(dir, 'cert') }
        expect(system(env, hook)).to be true
        log = File.join(dir, 'restarted')
        expect(File.exist?(log) ? File.read(log).split : []).to eq(restarted)
      end
    end
  end

  it 'refuses a plaintext Basic password' do
    klass = Chef::Resource.resource_for_node(:homelab_loadbalancer_dataplaneapi, chef_run.node)
    expect { klass.new('default').password_hash('plaintext') }.to raise_error(Chef::Exceptions::ValidationFailed)
  end

  it 'refuses a wildcard status and metrics address' do
    klass = Chef::Resource.resource_for_node(:homelab_loadbalancer_agent, chef_run.node)
    expect { klass.new('default').metrics_address('0.0.0.0:9641') }.to raise_error(Chef::Exceptions::ValidationFailed)
  end

  context 'without an environment' do
    default_attributes['homelab_loadbalancer'] = { 'environment' => nil }

    it 'fails instead of trusting some CA' do
      expect { chef_run }.to raise_error(RuntimeError, /environment must be set/)
    end
  end
end
