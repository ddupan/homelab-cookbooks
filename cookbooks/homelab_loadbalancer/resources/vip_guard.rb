# Rejects traffic to the VIP pool that would land on a wildcard-bound socket, i.e.
# on anything but a listener bound to that VIP (HAProxy's). Host services are
# moved off the wildcard (homelab_base.listen_address); this catches whatever a
# package starts on 0.0.0.0 later, without keeping a list of ports.
unified_mode true

property :vip_pool, String, name_property: true

action :install do
  apt_package 'nftables'

  directory '/etc/ayatori-lb'

  # Own table, replaced atomically: never touches the rest of the ruleset.
  file '/etc/ayatori-lb/vip-guard.nft' do
    content <<~NFT
      # Managed by Cinc (homelab_loadbalancer)
      table inet ayatori_vip_guard
      delete table inet ayatori_vip_guard
      table inet ayatori_vip_guard {
        chain input {
          type filter hook input priority filter; policy accept;
          ip daddr #{new_resource.vip_pool} socket wildcard 1 reject
        }
      }
    NFT
    mode '0644'
    notifies :restart, 'service[ayatori-vip-guard]'
  end

  # nftables.service flushes the whole ruleset on start and reload; follow it.
  systemd_unit 'ayatori-vip-guard.service' do
    content <<~UNIT
      [Unit]
      Description=Reject VIP traffic to wildcard listeners
      After=nftables.service
      PartOf=nftables.service
      ReloadPropagatedFrom=nftables.service
      Before=haproxy.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/sbin/nft -f /etc/ayatori-lb/vip-guard.nft
      ExecReload=/usr/sbin/nft -f /etc/ayatori-lb/vip-guard.nft
      ExecStop=/usr/sbin/nft delete table inet ayatori_vip_guard

      [Install]
      WantedBy=multi-user.target nftables.service
    UNIT
    action [:create, :enable]
    notifies :restart, 'service[ayatori-vip-guard]'
  end

  service 'ayatori-vip-guard' do
    action :start
  end
end
