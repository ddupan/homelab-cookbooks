# Every key without a default is required and comes from the node policy in
# homelab-infra. Nothing here is secret.
# The Ayatori release whose compute-agent runs here; the tarball is a release attachment.
default['homelab_compute']['agent']['version'] = nil
# Defaults to that release's download URL; Kitchen points it at a fixture directory.
default['homelab_compute']['agent']['url_base'] = nil
# Memory kept for the host itself, subtracted from the Node's allocatable (Ayatori
# ADR-0015 resource model). Must cover the host's processes plus kernel headroom.
default['homelab_compute']['host_reserved_memory'] = '2Gi'
# Labels the agent cannot discover, e.g. topology.kubernetes.io/zone (ADR-0019 §4),
# like kubelet's --node-labels. Never node-role.kubernetes.io/*: the agent refuses them.
default['homelab_compute']['node_labels'] = {}
