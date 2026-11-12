# Every key without a default is required and comes from the node policy in
# homelab-infra. Nothing here is secret.
# LAN resolver for DNS endpoints (Blocky, which forwards lab.ddupan.top to PowerDNS).
default['homelab_loadbalancer']['resolver'] = '192.168.10.127:53'
default['homelab_loadbalancer']['bgp']['local_as'] = nil
default['homelab_loadbalancer']['bgp']['neighbors'] = {} # address => peer AS
default['homelab_loadbalancer']['bgp']['vip_pool'] = nil # only /32s from it are announced
# The Ayatori release whose lb-agent runs here; the tarball is a release attachment.
default['homelab_loadbalancer']['agent']['version'] = nil
# Defaults to that release's download URL; Kitchen points it at a fixture directory.
default['homelab_loadbalancer']['agent']['url_base'] = nil
# Ayatori ADR-0025, e.g. '30s': only with a release that knows gracefulRestartTime.
default['homelab_loadbalancer']['agent']['graceful_restart_time'] = nil
# VIPs are local addresses on this host: any wildcard listener would answer on every
# VIP and keep its port from ever being used by one. Host services bind the host IP.
default['homelab_base']['listen_address'] = node['ipaddress']
