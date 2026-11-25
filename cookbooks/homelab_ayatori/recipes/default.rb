# Ayatori API-only control plane (Ayatori ADR-0013): k0s controller-only as a systemd
# service; ESO, Flux and ayatori-manager as podman quadlets on the host network, each
# with its own client certificate (ADR-0021). Chef owns the node and the bootstrap
# objects Flux needs to start; everything else in the API comes from Flux.
ay = node['homelab_ayatori']
%w(environment release image).each do |key|
  raise "homelab_ayatori.#{key} must be set by the node policy" if ay[key].nil?
end
raise 'homelab_ayatori.environment must be dev or prod' unless %w(dev prod).include?(ay['environment'])
%w(name host port).each do |key|
  raise "homelab_ayatori.postgresql_instance.#{key} must be set" if ay['postgresql_instance'][key].nil?
end

env = ay['environment']
api = ay['api_address'] || node['ipaddress']
state = '/var/lib/ayatori-deploy'
identities_dir = '/etc/ayatori-control-plane'
textfile_dir = '/var/lib/prometheus/node-exporter' # homelab_base's node_exporter
namespace = 'ayatori-system'
loadbalancer = ay['loadbalancer']['address_pool']
gitops = ay['gitops'].to_h.empty? ? nil : ay['gitops'].to_h
oidc = ay['oidc'].to_h.empty? ? nil : ay['oidc'].to_h
if oidc && (oidc['issuer'].to_s.empty? || Array(oidc['audiences']).empty?)
  raise 'homelab_ayatori.oidc needs issuer and audiences'
end
spiffe_issuer = ay['spiffe_issuer']
raise 'homelab_ayatori.spiffe_issuer needs oidc for its audiences' if spiffe_issuer && !oidc
# `ayatori config add` reads where to sign in from this ConfigMap before it has a token
# (Ayatori ADR-0027): the only path anonymous requests may use.
LOGIN_DISCOVERY = '/api/v1/namespaces/kube-public/configmaps/ayatori-login'.freeze

package %w(podman openssl)

directory state do
  mode '0700'
end

# --- k0s -----------------------------------------------------------------------------

# Structured authentication (Kubernetes AuthenticationConfiguration): people sign in with
# iam-login. Outside /etc/k0s, which only root can read: kube-apiserver runs as its own
# user. Nothing in it is secret. The apiserver reloads it on change; adding or removing
# the flag restarts k0s through k0s.yaml. Its anonymous section also makes k0s drop its
# --anonymous-auth=false default, which kube-apiserver refuses alongside the section.
AUTHENTICATION_CONFIG = '/etc/ayatori-apiserver/authentication.yaml'.freeze
directory ::File.dirname(AUTHENTICATION_CONFIG) do
  mode '0755'
  action oidc ? :create : :delete
  recursive true
end

# Nodes, instances and automation (Ayatori ADR-0027): SPIRE's JWT-SVIDs for the same audiences; the
# username is the SPIFFE ID, which cannot collide with "oidc:" users.
spiffe_jwt = spiffe_issuer && <<~YAML.gsub(/^/, '  ').strip
  - issuer:
      url: #{spiffe_issuer.to_json}
      audiences: #{Array(oidc['audiences']).to_json}
      audienceMatchPolicy: MatchAny
    claimMappings:
      username:
        claim: sub
        prefix: ""
YAML

file AUTHENTICATION_CONFIG do
  content(oidc && <<~YAML)
    # Managed by Cinc (homelab_ayatori)
    apiVersion: apiserver.config.k8s.io/v1
    kind: AuthenticationConfiguration
    jwt:
      - issuer:
          url: #{oidc['issuer'].to_json}
          audiences: #{Array(oidc['audiences']).to_json}
          audienceMatchPolicy: MatchAny
        claimMappings:
          username:
            claim: preferred_username
            prefix: "oidc:"
          groups:
            claim: groups
            prefix: "oidc:"
      #{spiffe_jwt}
    anonymous:
      enabled: true
      conditions:
        - path: #{LOGIN_DISCOVERY}
  YAML
  mode '0644'
  action oidc ? :create : :delete
end

homelab_ayatori_k0s 'default' do
  version ay['k0s']['version']
  sha256 ay['k0s']['sha256']
  config <<~YAML
    # Managed by Cinc (homelab_ayatori)
    apiVersion: k0s.k0sproject.io/v1beta1
    kind: ClusterConfig
    metadata:
      name: k0s
    spec:
      api:
        address: #{api}
        sans: #{["#{node['hostname']}.lab.ddupan.top"].to_json}
#{oidc ? "        extraArgs:\n          authentication-config: #{AUTHENTICATION_CONFIG}\n" : ''}      controllerManager:
        extraArgs:
          # API-only 不运行 Pod：只保留 namespace 删除收尾，以及客户端证书（Ayatori ADR-0021）的
          # 签发与过期 bootstrap token、CSR 的清理。签发使用 k0s 的 CA。
          controllers: namespace,csrsigning,csrcleaner,tokencleaner
      storage:
        type: etcd
      telemetry:
        enabled: false
  YAML
  install_args "--config /etc/k0s/k0s.yaml --disable-components #{ay['k0s']['disabled_components'].join(',')} " \
               "#{ay['k0s']['controller_flags'].join(' ')}"
end

# --- third-party APIs and the bootstrap objects Flux needs ----------------------------

eso = "#{state}/external-secrets-#{ay['eso']['version']}.yaml"
remote_file eso do
  source "https://github.com/external-secrets/external-secrets/releases/download/#{ay['eso']['version']}/external-secrets.yaml"
  checksum ay['eso']['manifest_sha256']
  mode '0600'
  retries 3
  retry_delay 10
end

# Outside a cluster only the CRDs and the controller ClusterRole apply; the Deployment,
# webhook and cert-controller do not.
file "#{state}/external-secrets-api.yaml" do
  content(lazy do
    YAML.load_stream(::File.read(eso)).compact.select do |d|
      d['kind'] == 'CustomResourceDefinition' ||
        (d['kind'] == 'ClusterRole' && d.dig('metadata', 'name') == 'external-secrets-controller')
    end.map(&:to_yaml).join
  end)
  mode '0600'
  only_if { ::File.exist?(eso) }
end

ay['flux']['crds'].each do |controller, sha256|
  remote_file "#{state}/#{controller}-#{ay['flux']['version']}.crds.yaml" do
    source "https://github.com/fluxcd/#{controller}/releases/download/#{ay['flux']['version']}/#{controller}.crds.yaml"
    checksum sha256
    mode '0600'
    retries 3
    retry_delay 10
  end
end

cookbook_file "#{state}/client-certificates.yaml" do
  source 'client-certificates.yaml'
  mode '0600'
end

template "#{state}/bootstrap.yaml" do
  source 'bootstrap.yaml.erb'
  mode '0600'
  sensitive false
  variables(
    control_namespace: namespace,
    repository: ay['repository'],
    release: ay['release'],
    environment: env,
    openbao_address: ay['openbao_address'],
    postgresql: ay['postgresql_instance'].to_h,
    loadbalancer: !loadbalancer.nil?,
    node_agents: ay['node_agents'],
    dns_api_key: ay['loadbalancer']['dns_api_key'].to_h,
    gitops: gitops,
    oidc_admin_groups: oidc ? Array(oidc['admin_groups']) : [],
    # The CLI's client is the environment's own audience (iam-login client ayatori-<env>).
    login: oidc && { 'issuer' => oidc['issuer'], 'client_id' => Array(oidc['audiences']).first },
    # k0s's CA, which the CLI pins after the user confirms its fingerprint. The template reads
    # it while rendering: homelab_ayatori_k0s has waited for the API, so k0s has generated it.
    login_ca: '/var/lib/k0s/pki/ca.crt'
  )
end

manifests = ["#{state}/external-secrets-api.yaml"] +
            ay['flux']['crds'].keys.map { |c| "#{state}/#{c}-#{ay['flux']['version']}.crds.yaml" } +
            ["#{state}/client-certificates.yaml", "#{state}/bootstrap.yaml"]
manifests.each do |path|
  homelab_ayatori_manifest path
end

# --- client certificates (ADR-0021) ---------------------------------------------------

identities = {
  'ayatori-controller' => 65_532,
  'external-secrets' => 65_534,
  'flux-source-controller' => 65_534,
  'flux-kustomize-controller' => 65_534,
  'kube-state-metrics' => 65_534,
}

directory identities_dir do
  mode '0755'
end

identities.each do |identity, uid|
  homelab_ayatori_client_identity identity do
    uid uid
    dir "#{identities_dir}/#{identity}"
    server "https://#{api}:6443"
    action :prepare
  end
end

# Root, to write each identity's files as that identity; only the file capabilities stay.
homelab_ayatori_container 'client-credentials' do
  image ay['image']
  entrypoint '/client-credentials'
  user 0
  capabilities %w(CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER)
  volumes ["#{identities_dir}:/identities"]
  exec(identities.keys.map { |i| "--identity=#{i}=/identities/#{i}" })
  # MemoryMax covers the whole unit cgroup, `podman run` and conmon included, not just the
  # binary: at 64M it sat at the limit and starts were intermittently killed by a signal.
  memory '256M'
  # A new bootstrap token restarts it: a certificate manager already waiting on a CSR
  # made with the old token would not ask again, and the deployer only approves CSRs
  # made with the token it just created.
  restart_on(identities.keys.map { |i| "#{identities_dir}/#{i}/bootstrap-kubeconfig" })
end

identities.each do |identity, uid|
  homelab_ayatori_client_identity identity do
    uid uid
    dir "#{identities_dir}/#{identity}"
    server "https://#{api}:6443"
    image ay['image']
    action :approve
  end
end

directory "#{identities_dir}/kube-state-metrics-config" do
  owner 65_534
  group 65_534
  mode '0500'
end

cookbook_file "#{identities_dir}/kube-state-metrics-config/custom-resource-state.yaml" do
  source 'custom-resource-state.yaml'
  owner 65_534
  group 65_534
  mode '0400'
end

# Public central CA, only for PostgreSQL verify-full; OpenBao uses the system roots.
remote_file "#{identities_dir}/ayatori-controller/postgresql-ca.crt" do
  source ay['postgresql_ca_source'] || "#{ay['openbao_address']}/v1/pki/ca/pem"
  owner 65_532
  mode '0444'
  retries 3
  retry_delay 10
end

# --- control plane containers ---------------------------------------------------------

# Agents that converge must be able to join first.
if ay['loadbalancer']['agent_convergence'] && !ay['node_agents']
  raise 'homelab_ayatori.loadbalancer.agent_convergence needs homelab_ayatori.node_agents'
end
dns = ay['loadbalancer']['dns'].to_h
unless dns.empty? || (dns['url'].to_s.match?(%r{\Ahttps?://}) && dns['zone'].to_s.match?(/\A[a-z0-9.-]+[a-z0-9]\z/))
  raise 'homelab_ayatori.loadbalancer.dns must be {url: http(s)://..., zone: <dns name>}'
end
lb_args = if loadbalancer
            ["--loadbalancer-address-pool=#{loadbalancer}",
             "--loadbalancer-credentials=#{namespace}/loadbalancer-credentials"] +
              (dns.empty? ? [] : ["--loadbalancer-dns-url=#{dns['url']}", "--loadbalancer-dns-zone=#{dns['zone']}"]) +
              (ay['loadbalancer']['agent_convergence'] ? ['--loadbalancer-agent-convergence'] : [])
          else
            []
          end

containers = {
  'external-secrets' => {
    image: ay['eso']['image'], identity: 'external-secrets', memory: '256M',
    exec: ["--namespace=#{namespace}", '--enable-cluster-store-reconciler=false',
           '--enable-cluster-external-secret-reconciler=false', '--enable-cluster-push-secret-reconciler=false',
           '--enable-generator-state=false', "--metrics-addr=#{api}:8180", '--live-addr=127.0.0.1:8182']
  },
  'flux-source-controller' => {
    image: ay['flux']['source_image'], identity: 'flux-source-controller', memory: '256M',
    env: { 'RUNTIME_NAMESPACE' => 'flux-system' }, volumes: ['flux-source-data:/data:U'],
    exec: ['--storage-path=/data', '--storage-addr=127.0.0.1:9090', '--storage-adv-addr=127.0.0.1:9090',
           "--metrics-addr=#{api}:8280", '--health-addr=127.0.0.1:9440']
  },
  'flux-kustomize-controller' => {
    image: ay['flux']['kustomize_image'], identity: 'flux-kustomize-controller', memory: '512M',
    env: { 'RUNTIME_NAMESPACE' => 'flux-system' },
    exec: ['--no-remote-bases', '--concurrent=1', '--concurrent-ssa=1',
           "--metrics-addr=#{api}:8281", '--health-addr=127.0.0.1:9441']
  },
  'ayatori-manager' => {
    image: ay['image'], identity: 'ayatori-controller', memory: '256M',
    exec: ['--leader-elect', "--leader-election-namespace=#{namespace}",
           '--health-probe-bind-address=127.0.0.1:8081', "--metrics-bind-address=#{api}:8080",
           '--metrics-secure=false', '--webhook-port=-1', '--zap-devel=false',
           "--openbao-address=#{ay['openbao_address']}", "--openbao-auth-mount=kubernetes-ayatori-#{env}",
           "--openbao-auth-role=ayatori-#{env}-controller", "--openbao-service-account-namespace=#{namespace}",
           '--openbao-service-account-name=database-openbao-login',
           # 登录 JWT 兼作 TokenReview 凭据，必须使用 API audience（k0s 默认值）。
           '--openbao-token-audience=https://kubernetes.default.svc',
           "--database-secret-namespace=#{namespace}", '--database-root-cert=/identity/postgresql-ca.crt',
           '--database-credential-mount=kv', "--database-credential-prefix=ayatori/#{env}/applications",
           '--database-provision-resources', "--database-credential-url-base=#{ay['openbao_address']}"] + lb_args
  },
  # 只导出 CR 状态（Flux 对象与 Ayatori 资源），不导出内置资源。
  'kube-state-metrics' => {
    image: ay['ksm']['image'], identity: 'kube-state-metrics', memory: '128M',
    volumes: ["#{identities_dir}/kube-state-metrics-config:/config:ro"],
    exec: ['--kubeconfig=/identity/kubeconfig', '--custom-resource-state-only',
           '--custom-resource-state-config-file=/config/custom-resource-state.yaml',
           "--host=#{api}", '--port=8085', '--telemetry-host=127.0.0.1', '--telemetry-port=8086']
  },
}

containers.each do |name, c|
  dir = "#{identities_dir}/#{c[:identity]}"
  homelab_ayatori_container name do
    image c[:image]
    user identities[c[:identity]]
    volumes ["#{dir}:/identity:ro"] + c.fetch(:volumes, [])
    env({ 'KUBECONFIG' => '/identity/kubeconfig' }.merge(c.fetch(:env, {})))
    exec c[:exec]
    memory c[:memory]
    restart_on ["#{dir}/kubeconfig"]
  end
end

# --- backup and certificate metrics ---------------------------------------------------

backup = ay['backup']['dir']
# The backup goes to an independent volume the deployer mounts; without it, fail
# instead of silently writing into the container rootfs.
ruby_block 'backup volume is mounted' do
  block { raise "#{backup} must be a mounted volume (homelab-infra mounts an Incus custom volume)" }
  not_if "mountpoint -q #{backup}"
end

systemd_unit 'ayatori-backup.service' do
  content <<~UNIT
    [Unit]
    Description=Ayatori k0s 备份（etcd、PKI、k0s.yaml）
    After=k0scontroller.service
    RequiresMountsFor=#{backup}

    [Service]
    Type=oneshot
    UMask=0077
    ExecStart=/usr/local/bin/k0s backup --save-path=#{backup}
    # 只保留最新 #{ay['backup']['keep']} 份。
    ExecStartPost=/bin/sh -c 'ls -1t #{backup}/k0s_backup_*.tar.gz | tail -n +#{ay['backup']['keep'] + 1} | xargs -r rm -f --'
    # 供 node_exporter textfile collector 判断备份新鲜度；只在成功后更新。
    ExecStartPost=/bin/sh -c 'f=#{textfile_dir}/ayatori_backup.prom; printf "%%s\\n" "# HELP ayatori_backup_last_success_timestamp_seconds 最近一次 k0s backup 成功完成的时间。" "# TYPE ayatori_backup_last_success_timestamp_seconds gauge" "ayatori_backup_last_success_timestamp_seconds $$(date +%%s)" > $$f.tmp && chmod 0644 $$f.tmp && mv $$f.tmp $$f'
  UNIT
  action :create
end

systemd_unit 'ayatori-backup.timer' do
  content <<~UNIT
    [Unit]
    Description=每日 Ayatori k0s 备份

    [Timer]
    OnCalendar=daily
    RandomizedDelaySec=1h
    Persistent=true

    [Install]
    WantedBy=timers.target
  UNIT
  action [:create, :enable, :start]
end

# homelab_base's node_exporter reads it; created here too so the order of the two
# recipes does not matter.
directory textfile_dir do
  recursive true
end

template '/usr/local/sbin/ayatori-cert-metrics' do
  source 'cert-metrics.sh.erb'
  mode '0755'
  variables(textfile_dir: textfile_dir, identities_dir: identities_dir)
end

systemd_unit 'ayatori-cert-metrics.service' do
  content <<~UNIT
    [Unit]
    Description=导出 Ayatori 证书到期时间
    After=k0scontroller.service

    [Service]
    Type=oneshot
    UMask=0077
    ExecStart=/usr/local/sbin/ayatori-cert-metrics
  UNIT
  action :create
end

systemd_unit 'ayatori-cert-metrics.timer' do
  content <<~UNIT
    [Unit]
    Description=每小时导出 Ayatori 证书到期时间

    [Timer]
    OnBootSec=5min
    OnUnitActiveSec=1h

    [Install]
    WantedBy=timers.target
  UNIT
  action [:create, :enable, :start]
end

# A first issuance or a renewal changes client.pem; refresh the metric right away
# instead of waiting for the hourly timer.
prom = "#{textfile_dir}/ayatori_certificates.prom"
service 'ayatori-cert-metrics.service' do
  action :start
  not_if "test -f #{prom} && [ -z \"$(find #{identities_dir} -name client.pem -newer #{prom})\" ]"
end
