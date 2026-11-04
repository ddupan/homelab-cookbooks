# Which shared-data roles this node holds; the node policy in homelab-infra sets them.
# Each adds its certificates or backup check to the maintenance metrics.
default['homelab_data']['postgresql_prod'] = false
default['homelab_data']['pgbackrest_repository'] = false
