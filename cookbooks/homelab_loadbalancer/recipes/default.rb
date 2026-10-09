# Ayatori LoadBalancer host. Chef owns the node — packages, base HAProxy config,
# systemd, BGP sessions and policy; Ayatori owns every lb_* section (through
# dataplaneapi) and every VIP path (through gobgpd). Nothing on the node is secret:
# the server certificate is ACME-issued, the client CA is public and the Basic
# password is only a crypt hash.
lb = node['homelab_loadbalancer']
%w(environment).each do |key|
  raise "homelab_loadbalancer.#{key} must be set by the node policy" if lb[key].nil?
end
raise 'homelab_loadbalancer.environment must be dev or prod' unless %w(dev prod).include?(lb['environment'])

address = node['ipaddress']
client_ca = '/etc/ayatori-lb/client-ca.pem'

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
  notifies :restart, 'service[gobgpd]'
end

homelab_loadbalancer_haproxy 'default' do
  resolver lb['resolver']
end

homelab_loadbalancer_dataplaneapi 'default' do
  listen address
  certificate lb['tls']['certificate']
  key lb['tls']['key']
  client_ca client_ca
  password_hash lb['dataplaneapi']['password_hash']
end

homelab_loadbalancer_gobgpd 'default' do
  router_id address
  local_as lb['bgp']['local_as']
  neighbors lb['bgp']['neighbors'].to_h
  vip_pool lb['bgp']['vip_pool']
  api_listen "#{address}:50051"
  certificate lb['tls']['certificate']
  key lb['tls']['key']
  client_ca client_ca
end

# Restart targets for the client CA above; the resources' own services live in their
# nested run contexts, which recipe-level notifications cannot reach.
%w(dataplaneapi gobgpd).each do |unit|
  service unit do
    action :nothing
  end
end
