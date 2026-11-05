# Baseline shared by every homelab Linux node. Each item is a custom resource so
# its behaviour is unit-tested once instead of re-implemented per Ansible role.

# bao serves a real Let's Encrypt cert and both endpoints are unauthenticated, so
# no token touches the node and a CA rotation is picked up on the next run.
base = node['homelab_base']
bao = base['bao']

# Shared with infrastructure/chef/converge.sh in homelab-infra: the last policy a
# manual converge applied. The drift timer why-runs against it.
policy_dir = '/var/lib/homelab-cinc/policy'
textfile_dir = '/var/lib/prometheus/node-exporter'
# drift = the timer (alerts); why-run = a manual preview of a new policy (does not
# alert, it is expected to differ); apply = a manual converge.
run_mode = ENV['HOMELAB_CINC_MODE'] || (Chef::Config[:why_run] ? 'why-run' : 'apply')

Chef.event_handler do
  on :run_completed do |_node, run_status|
    HomelabBase::RunReport.write(textfile_dir, run_mode, true, run_status.updated_resources.size)
  end
  on :run_failed do |_exception, run_status|
    HomelabBase::RunReport.write(textfile_dir, run_mode, false, run_status.updated_resources.size)
  end
end

# Not in why-run: a periodic apt update is always "due" once a day, and the daily
# drift check would report that as drift. Manual converges still refresh the cache.
unless Chef::Config[:why_run]
  apt_update 'daily' do
    frequency 86_400
    # The WAN drops at random; a fresh etcd-pve3 failed its first converge on this.
    retries 3
    retry_delay 10
    action :periodic
  end
end

homelab_base_ca_trust 'ddupan-internal-ca' do
  source "#{bao}/v1/pki/ca/pem"
end

homelab_base_ssh_ca_trust "#{bao}/v1/ssh-client-signer/public_key" do
  listen base['listen_address'] if base['listen_address']
end

homelab_base_node_exporter 'default' do
  textfile_dir textfile_dir
  listen "#{base['listen_address']}:9100" if base['listen_address']
  extra_args base['node_exporter']['extra_args'].to_a
end

homelab_base_drift_check policy_dir

homelab_base_spire_node_cert 'default' do
  server "#{bao}/v1/pki-spire-nodes/roles/node/acme/directory"
  domain "#{node['hostname']}.#{base['domain']}"
end

homelab_base_spire_agent 'default' do
  server_address base['spire_server']
  trust_domain base['trust_domain']
end
