# Baseline shared by every homelab Linux node. Each item is a custom resource so
# its behaviour is unit-tested once instead of re-implemented per Ansible role.

# bao serves a real Let's Encrypt cert and both endpoints are unauthenticated, so
# no token touches the node and a CA rotation is picked up on the next run.
# By HOSTNAME: the cert has a DNS SAN only.
bao = 'https://bao.ad.ddupan.top:8200'

# Shared with infrastructure/chef/converge.sh in homelab-infra: the last policy a
# manual converge applied. The drift timer why-runs against it.
policy_dir = '/var/lib/homelab-cinc/policy'
textfile_dir = '/var/lib/prometheus/node-exporter'
run_mode = Chef::Config[:why_run] ? 'why-run' : 'apply'

Chef.event_handler do
  on :run_completed do |_node, run_status|
    HomelabBase::RunReport.write(textfile_dir, run_mode, true, run_status.updated_resources.size)
  end
  on :run_failed do |_exception, run_status|
    HomelabBase::RunReport.write(textfile_dir, run_mode, false, run_status.updated_resources.size)
  end
end

# Not in why-run: a periodic apt update is always "due" once a day, and the hourly
# drift check would report that as drift. Manual converges still refresh the cache.
unless Chef::Config[:why_run]
  apt_update 'daily' do
    frequency 86_400
    action :periodic
  end
end

homelab_base_ca_trust 'ddupan-internal-ca' do
  source "#{bao}/v1/pki/ca/pem"
end

homelab_base_ssh_ca_trust "#{bao}/v1/ssh-client-signer/public_key"

homelab_base_node_exporter 'default' do
  textfile_dir textfile_dir
end

homelab_base_drift_check policy_dir
