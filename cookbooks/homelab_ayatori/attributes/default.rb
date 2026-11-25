# Every key without a default is required and comes from the node policy in
# homelab-infra. Nothing here is secret.
ay = default['homelab_ayatori']
ay['environment'] = nil # dev | prod
# The Ayatori release this node runs: the Flux GitRepository follows this tag, and the
# manager image must be the same release, pinned by digest (a release may be re-pushed
# under the same tag; the digest makes that an explicit policy change).
ay['release'] = nil
ay['image'] = nil # zot.lab.ddupan.top/panxiao81/ayatori-manager:<release>@sha256:...
ay['postgresql_instance'] = {} # name, host, port; hostaddr only where the Ayatori release still requires it
# Optional: Flux syncs Tenants/Databases (and LoadBalancerHosts) from this repo path.
ay['gitops'] = {} # url, path, branch
# Optional: enables the LoadBalancer controller with this VIP pool.
ay['loadbalancer']['address_pool'] = nil
# Optional: Hostnames in the PowerDNS zone Ayatori owns ({url, zone}).
ay['loadbalancer']['dns'] = {}
# The PowerDNS API key in Bao KV, read in place by ESO. Read even without dns: the
# credentials Secret is one object and ESO cannot leave a field out conditionally.
ay['loadbalancer']['dns_api_key'] = { 'path' => 'k8s/powerdns', 'property' => 'api_key' }
# Ayatori ADR-0021/0022: node agents (compute, loadbalancer) join this control plane —
# Flux syncs deploy/flux/nodes, their Node and Lease permissions. Needs a release that
# has it. First certificates: homelab-infra infrastructure/chef/ansible/join.yml.
ay['node_agents'] = false
# ADR-0022: LB hosts converge HAProxy themselves and the manager only aggregates their
# reports. Switched per environment together with the LB policy's agent.converge.
ay['loadbalancer']['agent_convergence'] = false

# Optional: people sign in with iam-login (OIDC) through structured authentication
# ({issuer, audiences, admin_groups}); audiences are the client IDs whose ID tokens this
# API accepts (one per environment, so a Dev token is refused by Prod). Users and groups
# appear prefixed "oidc:"; admin_groups (AD groups) are bound to cluster-admin here, any
# finer RBAC is the API's own. Empty = client certificates and service accounts only.
ay['oidc'] = {}

# Optional, with oidc: nodes, instances and automation authenticate with SPIFFE JWT-SVIDs
# (Ayatori ADR-0027) — the issuer of SPIRE's OIDC discovery provider. They use the same
# audiences as oidc (the environment's), and the username is the SPIFFE ID itself
# (spiffe://…, no prefix). RBAC for them is the API's own. nil = people only.
ay['spiffe_issuer'] = nil

# ayatori-api (Ayatori ADR-0027): the aggregated subresources (database credentials), from
# the same image as the manager. Turn on only with a release whose image has /ayatori-api.
ay['ayatori_api'] = false

# Site endpoints: defaults the node policy may override.
ay['openbao_address'] = 'https://bao.lab.ddupan.top:8200'
ay['repository'] = 'https://github.com/ddupan/ayatori.git'
# nil = node['ipaddress'].
ay['api_address'] = nil
# Central CA for PostgreSQL verify-full; nil = Bao's pki/ CA. Kitchen points it at a fixture.
ay['postgresql_ca_source'] = nil

ay['backup']['dir'] = '/var/backups/ayatori' # an independent volume, mounted by the deployer
ay['backup']['keep'] = 7

# Third-party components, upgraded together after Dev validates them.
# renovate: datasource=github-releases depName=k0sproject/k0s
ay['k0s']['version'] = 'v1.36.4+k0s.1'
ay['k0s']['sha256'] = '18c304d53cdd70095e99c6b859b269b4fef0bb84579d7e7185271a9135694a31'
# API-only: apiserver, etcd, a kube-controller-manager with only the controllers listed
# in the k0s config, and k0s's own RBAC.
ay['k0s']['controller_flags'] = %w(--logging=etcd=warn --verbose=false)
ay['k0s']['disabled_components'] = %w(
  autopilot control-api coredns csr-approver endpoint-reconciler helm
  konnectivity-server kube-proxy kube-scheduler metrics-server network-provider
  node-role update-prober windows-node
)
ay['eso']['version'] = 'v2.11.0'
ay['eso']['image'] = 'ghcr.io/external-secrets/external-secrets@sha256:66fb710878cbf3eba4a927e35c5d75e29a202c9bab238aad64bfb23b786b962b'
ay['eso']['manifest_sha256'] = 'c427124642886d240af8f28d294714a168d920ef8e5d55db14600e00ed0cfb80'
ay['flux']['version'] = 'v1.9.6'
ay['flux']['source_image'] = 'ghcr.io/fluxcd/source-controller@sha256:6a6693172589f8ff26123a231d5fa6ceb194a6efb4dc647cdf057c959f76a2e3'
ay['flux']['kustomize_image'] = 'ghcr.io/fluxcd/kustomize-controller@sha256:2ebeaa341da77d52b6abbbba5efcee0450d47f8b42f0e6f33b08f9020262d606'
ay['flux']['crds'] = {
  'source-controller' => '5acf3b01c24f15647a162f2d43b1287f0d0156fab0026f4afb9865874cdbe16d',
  'kustomize-controller' => 'b9e74622f9f3d87950f59641651fe0ea0220367c1d6f34a72c9591552afda292',
}
ay['ksm']['image'] = 'registry.k8s.io/kube-state-metrics/kube-state-metrics@sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b'

# The control plane's systemd units, for homelab_base's node_exporter (alerts use
# node_systemd_unit_state).
default['homelab_base']['node_exporter']['extra_args'] = [
  '--collector.systemd',
  '--collector.systemd.unit-include=^(k0scontroller|client-credentials|external-secrets|flux-source-controller|' \
  'flux-kustomize-controller|ayatori-manager|kube-state-metrics|ayatori-backup|ayatori-cert-metrics)[.]service$',
]
