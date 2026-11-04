# Ayatori LB agent (ADR-0014/0015): decides on this host alone whether each VIP is
# announced — the VIP is local, HAProxy serves it, a session is up — and speaks BGP
# itself (embedded GoBGP, outbound sessions only). Read-only /status and /metrics on
# the node address; the controller only observes.
#
# Released with Ayatori, not GoBGP or HAProxy: the tarball and checksum list are
# attachments of the Ayatori release.
unified_mode true

property :version, String, required: true
property :url_base, String, default: lazy { "https://git.ddupan.top/panxiao81/ayatori/releases/download/v#{version}" }
property :router_id, String, required: true
property :local_as, Integer, required: true
property :neighbors, Hash, required: true,
                           callbacks: { 'needs at least one neighbor' => ->(v) { !v.empty? } }
property :vip_pool, String, required: true
# Ayatori ADR-0022. join: the agent joins the control plane as a Node of role
# loadbalancer, its certificate in CREDENTIALS. The first certificate comes from
# homelab-infra's join playbook, never from Cinc; until then the agent announces as
# before and retries. data_plane (needs join): converge HAProxy on this host through the
# loopback Data Plane API instead of the controller writing to it remotely — the
# environment's manager runs with --loadbalancer-agent-convergence at the same time.
property :join, [true, false], default: false
property :data_plane, [Hash, nil]
property :metrics_address, String, required: true,
                                   callbacks: { 'must bind a specific address, never all interfaces' => lambda { |v|
                                     !v.start_with?('0.0.0.0:', ':', '[::]:')
                                   } }

CREDENTIALS = '/etc/ayatori/lb-agent'.freeze

action :install do
  raise 'homelab_loadbalancer_agent: data_plane needs join' if new_resource.data_plane && !new_resource.join

  homelab_base_verified_release '/usr/local/bin/ayatori-lb-agent' do
    url_base new_resource.url_base
    tarball "ayatori-lb-agent_#{new_resource.version}_linux_amd64.tar.gz"
    checksums "ayatori_#{new_resource.version}_checksums.txt"
    install_dir "/opt/ayatori-lb-agent-#{new_resource.version}"
    binary 'lb-agent'
    notifies :restart, 'service[ayatori-lb-agent]'
  end

  # Group haproxy: agent.sock (level operator) in base.cfg is 0660 root:haproxy. Nothing
  # else on the host is readable or writable to it.
  user 'ayatori-lb-agent' do
    system true
    shell '/usr/sbin/nologin'
    home '/nonexistent'
    manage_home false
  end

  group 'haproxy' do
    members ['ayatori-lb-agent']
    append true
    action :modify
  end

  directory '/etc/ayatori'

  # Owned by the agent: it writes its key and certificate here. Created empty; the
  # deployer writes bootstrap-kubeconfig on join.
  if new_resource.join
    directory CREDENTIALS do
      owner 'ayatori-lb-agent'
      mode '0700'
    end
  end

  config = {
    'asn' => new_resource.local_as,
    'routerID' => new_resource.router_id,
    'neighbors' => new_resource.neighbors.sort.map { |address, peer_as| { 'address' => address, 'asn' => Integer(peer_as) } },
    'vipPool' => new_resource.vip_pool,
    'haproxySocket' => '/run/haproxy/agent.sock',
    'metricsAddress' => new_resource.metrics_address,
  }
  config.merge!('nodeName' => node['hostname'], 'credentialsDir' => CREDENTIALS) if new_resource.join
  config['dataPlane'] = new_resource.data_plane if new_resource.data_plane

  # JSON is valid YAML, and the agent parses it strictly: an unknown key fails at start.
  file '/etc/ayatori/lb-agent.yaml' do
    content(JSON.pretty_generate(config) + "\n")
    mode '0644'
    notifies :restart, 'service[ayatori-lb-agent]'
  end

  # Not BindsTo=haproxy: with HAProxy down the agent withdraws the paths itself (its
  # frontends are no longer open) and keeps reporting why. WantedBy brings it up with
  # HAProxy at boot. CAP_NET_ADMIN only to add the VIP /32s to lo — the LB hosts are
  # unprivileged LXC, so no dummy interface.
  # Only the credentials directory is writable; without join the unit stays as it was.
  writable = new_resource.join ? "ReadWritePaths=#{CREDENTIALS}\n" : ''
  systemd_unit 'ayatori-lb-agent.service' do
    content <<~UNIT
      [Unit]
      Description=Ayatori LoadBalancer agent
      After=haproxy.service network-online.target
      Wants=network-online.target

      [Service]
      User=ayatori-lb-agent
      SupplementaryGroups=haproxy
      AmbientCapabilities=CAP_NET_ADMIN
      CapabilityBoundingSet=CAP_NET_ADMIN
      NoNewPrivileges=yes
      ProtectSystem=strict
      ProtectHome=yes
      PrivateTmp=yes
      #{writable}ExecStart=/usr/local/bin/ayatori-lb-agent -config /etc/ayatori/lb-agent.yaml
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=haproxy.service
    UNIT
    action [:create, :enable]
    notifies :restart, 'service[ayatori-lb-agent]'
  end

  service 'ayatori-lb-agent' do
    action :start
  end
end
