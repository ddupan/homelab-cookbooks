# Baseline shared by every homelab Linux node. Each item is a custom resource so
# its behaviour is unit-tested once instead of re-implemented per Ansible role.

# bao serves a real Let's Encrypt cert and both endpoints are unauthenticated, so
# no token touches the node and a CA rotation is picked up on the next run.
# By HOSTNAME: the cert has a DNS SAN only.
bao = 'https://bao.ad.ddupan.top:8200'

apt_update 'daily' do
  frequency 86_400
  action :periodic
end

homelab_base_ca_trust 'ddupan-internal-ca' do
  source "#{bao}/v1/pki/ca/pem"
end

homelab_base_ssh_ca_trust "#{bao}/v1/ssh-client-signer/public_key"

# ponytail: ohai's default-route address; a multi-homed node needs an explicit listen.
homelab_base_node_exporter "#{node['ipaddress']}:9100"
