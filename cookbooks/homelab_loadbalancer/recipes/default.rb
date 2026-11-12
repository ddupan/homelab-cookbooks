# Ayatori LoadBalancer host. Chef owns the node — packages, base HAProxy config,
# systemd, the agent; Ayatori's agent on this host owns every lb_* section (through the
# loopback Data Plane API, ADR-0022) and decides which VIPs it announces (ADR-0014).
# The one secret, the agent's loopback Data Plane API password, is generated here and
# never leaves the host.
require 'securerandom'

lb = node['homelab_loadbalancer']
raise 'homelab_loadbalancer.agent.version must be set by the node policy' if lb['agent']['version'].nil?

address = node['ipaddress']

# Until Ayatori ADR-0022 the controller wrote through dataplaneapi on <node>:5555 over
# mTLS, with an ACME server certificate and the environment's client CA. Neither is
# needed any more; remove what earlier runs left. lego stays: homelab_base uses it too.
systemd_unit 'ayatori-lb-cert.timer' do
  action [:stop, :disable, :delete]
end

systemd_unit 'ayatori-lb-cert.service' do
  action :delete
end

%w(/usr/local/sbin/ayatori-lb-cert /usr/local/sbin/ayatori-lb-cert-deploy /etc/ayatori-lb/client-ca.pem).each do |path|
  file path do
    action :delete
  end
end

%w(/etc/ayatori-lb/tls /var/lib/ayatori-lb-acme).each do |path|
  directory path do
    recursive true
    action :delete
  end
end

directory '/etc/ayatori-lb'

homelab_loadbalancer_vip_guard lb['bgp']['vip_pool']

homelab_loadbalancer_haproxy 'default' do
  resolver lb['resolver']
end

# The agent writes through a loopback listener, as its own user.
local_port = 5556
local_password = '/etc/ayatori/lb-agent-dataplane.password'

# Before dataplaneapi: it creates the agent user and the local password file it owns.
homelab_loadbalancer_agent 'default' do
  version lb['agent']['version']
  url_base lb['agent']['url_base'] if lb['agent']['url_base']
  router_id address
  local_as lb['bgp']['local_as']
  neighbors lb['bgp']['neighbors'].to_h
  vip_pool lb['bgp']['vip_pool']
  metrics_address "#{address}:9641"
  join true
  graceful_restart_time lb['agent']['graceful_restart_time']
  data_plane('url' => "http://127.0.0.1:#{local_port}", 'username' => 'lb-agent', 'passwordFile' => local_password)
end

homelab_loadbalancer_dataplaneapi 'default' do
  local_port local_port
  local_password_file local_password
end

# gobgpd announced on Ayatori's behalf until 0.3.0. Left running beside the agent it
# would be a second BGP speaker for the same router ID.
service 'gobgpd' do
  action [:stop, :disable]
end

%w(/etc/systemd/system/gobgpd.service /usr/local/bin/gobgpd /usr/local/bin/gobgp).each do |path|
  file path do
    action :delete
    notifies :run, 'execute[systemctl daemon-reload]' if path.end_with?('.service')
  end
end

execute 'systemctl daemon-reload' do
  action :nothing
end

directory '/etc/gobgpd' do
  recursive true
  action :delete
end

Dir.glob('/opt/gobgp-*').each do |path|
  directory path do
    recursive true
    action :delete
  end
end
