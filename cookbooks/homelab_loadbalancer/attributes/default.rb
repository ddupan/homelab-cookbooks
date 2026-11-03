# Every key without a default is required and comes from the node policy in
# homelab-infra. Nothing here is secret: the Basic password is a crypt hash and the
# client CA is public.
default['homelab_loadbalancer']['environment'] = nil # dev | prod
# Site endpoints: defaults the node policy may override, like the required keys.
default['homelab_loadbalancer']['bao'] = 'https://bao.lab.ddupan.top:8200'
# Ayatori addresses the host as <hostname>.<domain>, the name its ACME cert carries.
default['homelab_loadbalancer']['domain'] = 'lab.ddupan.top'
# LAN resolver for DNS endpoints (Blocky, which forwards lab.ddupan.top to PowerDNS).
default['homelab_loadbalancer']['resolver'] = '192.168.10.127:53'
default['homelab_loadbalancer']['dataplaneapi']['password_hash'] = nil
default['homelab_loadbalancer']['bgp']['local_as'] = nil
default['homelab_loadbalancer']['bgp']['neighbors'] = {} # address => peer AS
default['homelab_loadbalancer']['bgp']['vip_pool'] = nil # only /32s from it are announced
# The Ayatori release whose lb-agent runs here; the tarball is a release attachment.
default['homelab_loadbalancer']['agent']['version'] = nil
# Defaults to that release's download URL; Kitchen points it at a fixture directory.
default['homelab_loadbalancer']['agent']['url_base'] = nil
# Defaults to the environment's root in Bao; Kitchen points it at a fixture file.
default['homelab_loadbalancer']['client_ca_source'] = nil
# VIPs are local addresses on this host: any wildcard listener would answer on every
# VIP and keep its port from ever being used by one. Host services bind the host IP.
default['homelab_base']['listen_address'] = node['ipaddress']
