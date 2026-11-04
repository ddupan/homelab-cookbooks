# Ayatori Compute Agent (ADR-0015): converges this host's libvirt networks, pools and
# domains from the Ayatori API and keeps doing so from local state while the control
# plane is away. Read-only /metrics on the node address.
#
# Cinc never touches credentials (ADR-0022): /etc/ayatori/compute-agent holds the
# bootstrap-kubeconfig the deployer writes on join and the certificate the agent
# requests and renews itself. Until the join wrote that file the unit does not start —
# without it the agent cannot request a certificate and the host is not admitted.
#
# Released with Ayatori: the tarball and checksum list are attachments of the release.
unified_mode true

property :version, String, required: true
property :url_base, String, default: lazy { "https://git.ddupan.top/panxiao81/ayatori/releases/download/v#{version}" }
property :node_name, String, required: true
property :host_reserved_memory, String, required: true
property :node_labels, Hash, default: {},
                             callbacks: { 'must not set role labels, the agent owns its role' => lambda { |v|
                               v.keys.none? { |k| k.start_with?('node-role.kubernetes.io/') }
                             } }
property :metrics_address, String, required: true,
                                   callbacks: { 'must bind a specific address, never all interfaces' => lambda { |v|
                                     !v.start_with?('0.0.0.0:', ':', '[::]:')
                                   } }

CREDENTIALS = '/etc/ayatori/compute-agent'.freeze

action :install do
  homelab_base_verified_release '/usr/local/bin/ayatori-compute-agent' do
    url_base new_resource.url_base
    tarball "ayatori-compute-agent_#{new_resource.version}_linux_amd64.tar.gz"
    checksums "ayatori_#{new_resource.version}_checksums.txt"
    install_dir "/opt/ayatori-compute-agent-#{new_resource.version}"
    binary 'compute-agent'
    notifies :restart, 'service[ayatori-compute-agent]'
  end

  directory '/etc/ayatori'

  # Created empty; its content belongs to the deployer and the agent.
  directory CREDENTIALS do
    mode '0700'
  end

  # JSON is valid YAML, and the agent parses it strictly: an unknown key fails at start.
  file '/etc/ayatori/compute-agent.yaml' do
    content(JSON.pretty_generate(
      'nodeName' => new_resource.node_name,
      'credentialsDir' => CREDENTIALS,
      'stateDir' => '/var/lib/ayatori/compute-agent',
      'hostReservedMemory' => new_resource.host_reserved_memory,
      'nodeLabels' => new_resource.node_labels.sort.to_h,
      'metricsAddress' => new_resource.metrics_address
    ) + "\n")
    mode '0644'
    notifies :restart, 'service[ayatori-compute-agent]'
  end

  # Root: it drives the system libvirt daemon and, with LXC and instance memory
  # guarantees (ADR-0015), cgroups on the host. Not Requires=libvirtd: with libvirt
  # down the agent keeps retrying and reports the node not ready.
  systemd_unit 'ayatori-compute-agent.service' do
    content <<~UNIT
      [Unit]
      Description=Ayatori Compute Agent
      After=libvirtd.service network-online.target
      Wants=network-online.target
      ConditionPathExists=#{CREDENTIALS}/bootstrap-kubeconfig

      [Service]
      ExecStart=/usr/local/bin/ayatori-compute-agent -config /etc/ayatori/compute-agent.yaml
      Restart=always
      RestartSec=5
      NoNewPrivileges=yes
      ProtectSystem=strict
      ReadWritePaths=#{CREDENTIALS}
      StateDirectory=ayatori/compute-agent
      StateDirectoryMode=0700
      ProtectHome=yes
      PrivateTmp=yes

      [Install]
      WantedBy=multi-user.target
    UNIT
    action [:create, :enable]
    notifies :restart, 'service[ayatori-compute-agent]'
  end

  # Before the join there is nothing to start (ConditionPathExists): starting anyway
  # would report a change on every converge. The join script starts it.
  service 'ayatori-compute-agent' do
    action :start
    only_if { ::File.exist?("#{CREDENTIALS}/bootstrap-kubeconfig") }
  end
end
