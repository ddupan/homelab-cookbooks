# ayatori-imds (Ayatori ADR-0016): the instance metadata service on 169.254.169.254.
# It intercepts requests on the instances' host ports with nftables, answers on
# per-instance sockets, and reads the instances from the compute agent's local state —
# nothing from the network, so it keeps answering while the control plane is away.
#
# Released with Ayatori, as its own tarball: Proxmox hosts will run it without the agent.
unified_mode true

property :version, String, required: true
property :url_base, String, default: lazy { "https://git.ddupan.top/panxiao81/ayatori/releases/download/v#{version}" }

action :install do
  homelab_base_verified_release '/usr/local/bin/ayatori-imds' do
    url_base new_resource.url_base
    tarball "ayatori-imds_#{new_resource.version}_linux_amd64.tar.gz"
    checksums "ayatori_#{new_resource.version}_checksums.txt"
    install_dir "/opt/ayatori-imds-#{new_resource.version}"
    binary 'imds'
    notifies :restart, 'service[ayatori-imds]'
  end

  # Root with only CAP_NET_ADMIN: it replaces its nftables tables, policy routes and the
  # ayimds0 dummy link, and sets src_valid_mark on instance bridges (net sysctls, so
  # ProtectKernelTunables stays off). ProtectSystem=strict leaves the agent's state
  # read-only to it. It keeps its rules when it stops: without them instance requests
  # would leave through the gateway.
  systemd_unit 'ayatori-imds.service' do
    content <<~UNIT
      [Unit]
      Description=Ayatori instance metadata service
      After=network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/ayatori-imds -state-dir /var/lib/ayatori/compute-agent
      Restart=always
      RestartSec=5
      CapabilityBoundingSet=CAP_NET_ADMIN
      NoNewPrivileges=yes
      ProtectSystem=strict
      ProtectHome=yes
      PrivateTmp=yes

      [Install]
      WantedBy=multi-user.target
    UNIT
    action [:create, :enable]
    notifies :restart, 'service[ayatori-imds]'
  end

  service 'ayatori-imds' do
    action :start
  end
end
