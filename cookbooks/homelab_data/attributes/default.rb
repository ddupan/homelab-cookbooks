# Which shared-data roles this node holds; the node policy in homelab-infra sets them.
# Each adds its certificates or backup check to the maintenance metrics.
default['homelab_data']['postgresql_prod'] = false
default['homelab_data']['pgbackrest_repository'] = false

# etcd member (recipe homelab_data::etcd). `members` maps every member's name (= the
# node's short hostname) to its address, this node included; the policy sets it.
# renovate: datasource=github-releases depName=etcd-io/etcd
default['homelab_data']['etcd']['version'] = '3.7.2'
default['homelab_data']['etcd']['members'] = {}
# Certificates are signed by Bao's existing pki/ roles homelab-etcd-*, logging in with
# this node's SPIFFE ID through jwt-spire. By HOSTNAME: bao's cert has DNS SANs only.
default['homelab_data']['etcd']['bao'] = 'https://bao.lab.ddupan.top:8200'
default['homelab_data']['etcd']['bao_role'] = 'homelab-etcd-member'
