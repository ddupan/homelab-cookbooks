# Site endpoints. Defaults only: a node policy in homelab-infra overrides them, so
# moving a service needs no cookbook release.
# bao by HOSTNAME: its cert has DNS SANs only.
default['homelab_base']['bao'] = 'https://bao.lab.ddupan.top:8200'
default['homelab_base']['spire_server'] = 'spire-server.lab.ddupan.top'
default['homelab_base']['trust_domain'] = 'ddupan.top'
# A node's lab DNS name is <hostname>.<domain>.
default['homelab_base']['domain'] = 'lab.ddupan.top'
