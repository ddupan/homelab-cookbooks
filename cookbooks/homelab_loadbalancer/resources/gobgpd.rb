# GoBGP speaker that announces each VIP as a /32 to the router. Ayatori adds and
# withdraws paths over its mTLS gRPC API; the sessions and the policy are static here.
#
# The policy is the safety net for that API: whatever a client asks for, only /32s
# inside the VIP pool ever reach the router, and nothing the router sends is kept.
# It must be the GLOBAL apply-policy — gobgpd silently ignores a neighbor-level one
# outside route-server mode (verified with two gobgpd v4.10.0 peers: everything was
# exported). The global import policy also filters locally added paths, so it uses
# the same VIP-only set instead of a bare reject.
unified_mode true

property :version, String, default: '4.10.0'
property :router_id, String, required: true
property :local_as, Integer, required: true
property :neighbors, Hash, required: true,
                           callbacks: { 'needs at least one neighbor' => ->(v) { !v.empty? } }
property :vip_pool, String, required: true
property :api_listen, String, required: true,
                              callbacks: { 'must bind a specific address, never all interfaces' => lambda { |v|
                                !v.start_with?('0.0.0.0:', ':', '[::]:')
                              } }
property :certificate, String, required: true
property :key, String, required: true
property :client_ca, String, required: true

action :install do
  homelab_base_verified_release '/usr/local/bin/gobgpd' do
    url_base "https://github.com/osrg/gobgp/releases/download/v#{new_resource.version}"
    tarball "gobgp_#{new_resource.version}_linux_amd64.tar.gz"
    checksums "gobgp_#{new_resource.version}_checksums.txt"
    install_dir "/opt/gobgp-#{new_resource.version}"
    binary 'gobgpd'
    notifies :restart, 'service[gobgpd]'
  end

  # The CLI ships in the same tarball.
  link '/usr/local/bin/gobgp' do
    to "/opt/gobgp-#{new_resource.version}/gobgp"
  end

  directory '/etc/gobgpd'

  neighbors = new_resource.neighbors.sort.map do |address, peer_as|
    <<~TOML
      [[neighbors]]
        [neighbors.config]
          neighbor-address = "#{address}"
          peer-as = #{Integer(peer_as)}
    TOML
  end

  file '/etc/gobgpd/gobgpd.toml' do
    content <<~TOML
      # Managed by Cinc (homelab_loadbalancer)
      [global.config]
        as = #{new_resource.local_as}
        router-id = "#{new_resource.router_id}"
        # Outbound sessions only: nothing needs to connect to this speaker.
        port = -1

      [global.apply-policy.config]
        import-policy-list = ["vip-only"]
        default-import-policy = "reject-route"
        export-policy-list = ["vip-only"]
        default-export-policy = "reject-route"

      [[defined-sets.prefix-sets]]
        prefix-set-name = "vip-pool"
        [[defined-sets.prefix-sets.prefix-list]]
          ip-prefix = "#{new_resource.vip_pool}"
          masklength-range = "32..32"

      [[policy-definitions]]
        name = "vip-only"
        [[policy-definitions.statements]]
          [policy-definitions.statements.conditions.match-prefix-set]
            prefix-set = "vip-pool"
          [policy-definitions.statements.actions]
            route-disposition = "accept-route"

      #{neighbors.join("\n")}
    TOML
    mode '0644'
    verify '/usr/local/bin/gobgpd --dry-run -t toml -f %{path}'
    notifies :restart, 'service[gobgpd]'
  end

  # BindsTo: if HAProxy stops, gobgpd stops with it and the router drops this host's
  # routes, instead of attracting traffic nothing serves. WantedBy brings it back when
  # HAProxy starts again; its paths are gone and Ayatori re-announces them. A HAProxy
  # reload is not a stop, so it does not touch the sessions.
  systemd_unit 'gobgpd.service' do
    content <<~UNIT
      [Unit]
      Description=GoBGP speaker for Ayatori LoadBalancer VIPs
      BindsTo=haproxy.service
      After=haproxy.service network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/gobgpd -t toml -f /etc/gobgpd/gobgpd.toml --pprof-disable --log-plain \\
        --api-hosts #{new_resource.api_listen} --tls --tls-cert-file #{new_resource.certificate} \\
        --tls-key-file #{new_resource.key} --tls-client-ca-file #{new_resource.client_ca}
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=haproxy.service
    UNIT
    action [:create, :enable]
    notifies :restart, 'service[gobgpd]'
  end

  service 'gobgpd' do
    action :start
  end
end
