# Ayatori LoadBalancer host. Chef owns the node — packages, base HAProxy config,
# systemd, the agent's BGP sessions; Ayatori owns every lb_* section (through
# dataplaneapi), and the agent decides on this host which VIPs it announces
# (ADR-0014). Nothing on the node is secret:
# the server certificate is ACME-issued (renewed by its own timer), the client CA is public and the Basic
# password is only a crypt hash. With agent.converge (ADR-0022) one secret is generated
# here: the loopback Data Plane API password of the host's own agent.
require 'securerandom'

lb = node['homelab_loadbalancer']
%w(environment).each do |key|
  raise "homelab_loadbalancer.#{key} must be set by the node policy" if lb[key].nil?
end
raise 'homelab_loadbalancer.agent.version must be set by the node policy' if lb['agent']['version'].nil?
raise 'homelab_loadbalancer.environment must be dev or prod' unless %w(dev prod).include?(lb['environment'])

address = node['ipaddress']
client_ca = '/etc/ayatori-lb/client-ca.pem'
certificate = '/etc/ayatori-lb/tls/server.crt'
key = '/etc/ayatori-lb/tls/server.key'

directory '/etc/ayatori-lb'

# Only certificates from this environment's own root are accepted: a Dev controller
# cannot manage a Prod host (homelab-infra infrastructure/openbao/terraform/pki-loadbalancer.tf).
remote_file client_ca do
  source lb['client_ca_source'] || "#{lb['bao']}/v1/pki-loadbalancer-#{lb['environment']}/ca/pem"
  mode '0644'
  retries 3
  retry_delay 10
  verify { |path| ::File.read(path).include?('-----BEGIN CERTIFICATE-----') }
  notifies :restart, 'service[dataplaneapi]'
end

homelab_loadbalancer_server_cert 'default' do
  server "#{lb['bao']}/v1/pki/acme/directory"
  domain "#{node['hostname']}.#{lb['domain']}"
  listen address
end

homelab_loadbalancer_vip_guard lb['bgp']['vip_pool']

homelab_loadbalancer_haproxy 'default' do
  resolver lb['resolver']
end

# Ayatori ADR-0022: with converge the agent writes through a loopback listener, as
# its own user, with a password generated here that never leaves the host.
converge = lb['agent']['converge']
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
  join lb['agent']['join']
  graceful_restart_time lb['agent']['graceful_restart_time']
  if converge
    data_plane('url' => "http://127.0.0.1:#{local_port}", 'username' => 'lb-agent', 'passwordFile' => local_password)
  end
end

homelab_loadbalancer_dataplaneapi 'default' do
  listen address
  certificate certificate
  key key
  client_ca client_ca
  password_hash lb['dataplaneapi']['password_hash']
  local_port local_port
  local_password_file local_password if converge
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

# Restart target for the client CA above; the resource's own service lives in its
# nested run context, which recipe-level notifications cannot reach.
service 'dataplaneapi' do
  action :nothing
end
