# Shared etcd member (homelab-infra infrastructure/etcd), formerly that component's
# Ansible role shared_etcd. Paths match it, so existing members are adopted in place.
#
# Cinc never restarts etcd. CI converges nodes in parallel; two members restarting at
# once loses quorum, and Patroni then demotes the pg-prod primary. A config, unit or
# binary change is only written; collect.py reports it as
# homelab_data_restart_pending{unit="homelab-etcd"} and members are restarted one at a
# time by hand (homelab-infra infrastructure/etcd/README.md). Certificates need no
# restart: etcd reloads them on every new connection.
etcd = node['homelab_data']['etcd']
name = node['hostname']
members = etcd['members'].to_h
raise "homelab_data.etcd.members must list this node (#{name})" unless members.key?(name)

address = members[name]
version = etcd['version']
install = '/opt/homelab-etcd'
config_dir = '/etc/homelab-etcd'
data_dir = '/var/lib/homelab-etcd'
snapshot_dir = '/var/backups/homelab-etcd'

package %w(python3 openssl) do
  options '--no-install-recommends'
  retries 3
  retry_delay 5
end

group 'homelab-etcd' do
  system true
end

user 'homelab-etcd' do
  gid 'homelab-etcd'
  system true
  shell '/usr/sbin/nologin'
  manage_home false
end

directory config_dir do
  group 'homelab-etcd'
  mode '0750'
end

directory data_dir do
  owner 'homelab-etcd'
  group 'homelab-etcd'
  mode '0700'
end

directory snapshot_dir do
  mode '0700'
end

release = "etcd-v#{version}-linux-amd64"
homelab_base_verified_release "#{install}/etcd" do
  url_base "https://github.com/etcd-io/etcd/releases/download/v#{version}"
  tarball "#{release}.tar.gz"
  checksums 'SHA256SUMS'
  install_dir install
  binary "#{release}/etcd"
end

%w(etcdctl etcdutl).each do |tool|
  link "#{install}/#{tool}" do
    to "#{install}/#{release}/#{tool}"
  end
end

# Certificates first: a new member cannot start without them.
file "#{config_dir}/cert.json" do
  content JSON.pretty_generate(
    'name' => name, 'address' => address, 'dir' => config_dir,
    'bao' => etcd['bao'], 'bao_role' => etcd['bao_role'],
    # 60-day certificates, renewed with 14 days left (as the Ansible role did).
    'ttl' => '1440h', 'renew_before_seconds' => 14 * 86_400
  ) + "\n"
  mode '0644'
end

cookbook_file '/usr/local/sbin/homelab-etcd-cert' do
  source 'homelab-etcd-cert'
  mode '0755'
end

systemd_unit 'homelab-etcd-cert.service' do
  content <<~UNIT
    [Unit]
    Description=Issue or renew this etcd member's certificates (Bao, SPIFFE)
    After=network-online.target spire-agent.service
    Wants=network-online.target
    [Service]
    Type=oneshot
    ExecStart=/usr/local/sbin/homelab-etcd-cert
    UMask=0077
    TimeoutStartSec=5min
  UNIT
  action :create
end

systemd_unit 'homelab-etcd-cert.timer' do
  content <<~UNIT
    [Unit]
    Description=Daily etcd certificate renewal check
    [Timer]
    OnCalendar=daily
    RandomizedDelaySec=1h
    Persistent=true
    [Install]
    WantedBy=timers.target
  UNIT
  action [:create, :enable, :start]
end

# First issuance on a new member, so its first converge leaves it ready to join.
# The script itself is idempotent; this only avoids running it on every converge.
# A oneshot: systemctl start returns when it has finished.
service 'homelab-etcd-cert' do
  action :start
  not_if { %w(server peer gateway admin).all? { |c| ::File.exist?("#{config_dir}/#{c}.crt") } }
end

initial_cluster = members.map { |n, a| "#{n}=https://#{a}:2380" }.join(',')
file "#{config_dir}/etcd.yml" do
  content <<~YAML
    # Managed by Cinc (homelab_data::etcd). Changes take effect on a manual restart.
    name: #{name.to_json}
    data-dir: #{data_dir.to_json}
    listen-client-urls: https://#{address}:2379
    advertise-client-urls: https://#{address}:2379
    listen-peer-urls: https://#{address}:2380
    initial-advertise-peer-urls: https://#{address}:2380
    initial-cluster: #{initial_cluster.to_json}
    initial-cluster-token: "homelab-shared-etcd-v1"
    # Only read on a member's first start. The cluster exists; a new member joins it
    # after `etcdctl member add` (see the unit's start condition).
    initial-cluster-state: existing
    client-transport-security:
      cert-file: #{config_dir}/server.crt
      key-file: #{config_dir}/server.key
      client-cert-file: #{config_dir}/gateway.crt
      client-key-file: #{config_dir}/gateway.key
      trusted-ca-file: #{config_dir}/ca.crt
      client-cert-auth: true
    peer-transport-security:
      cert-file: #{config_dir}/peer.crt
      key-file: #{config_dir}/peer.key
      trusted-ca-file: #{config_dir}/ca.crt
      client-cert-auth: true
      allowed-cn: [homelab-etcd-peer]
    # Metrics/health only, no KV API; loopback and the member address only.
    listen-metrics-urls: "http://127.0.0.1:2381,http://#{address}:2381"
    quota-backend-bytes: 268435456
    auto-compaction-mode: periodic
    auto-compaction-retention: '1h'
    heartbeat-interval: 100
    election-timeout: 1000
    logger: zap
    log-level: info
  YAML
  group 'homelab-etcd'
  mode '0640'
end

# Starts only on a member that has data, or that the join runbook marked after
# `etcdctl member add`. Without this a fresh node would start on its first converge,
# before the cluster knows it, and crash-loop.
systemd_unit 'homelab-etcd.service' do
  content <<~UNIT
    [Unit]
    Description=Homelab shared etcd
    Wants=network-online.target
    After=network-online.target
    ConditionPathExists=|#{data_dir}/member
    ConditionPathExists=|#{config_dir}/join
    [Service]
    User=homelab-etcd
    Group=homelab-etcd
    ExecStart=#{install}/etcd --config-file=#{config_dir}/etcd.yml
    Restart=on-failure
    RestartSec=5
    TimeoutStopSec=60
    MemoryHigh=256M
    MemoryMax=384M
    UMask=0077
    NoNewPrivileges=true
    ProtectSystem=strict
    ProtectHome=true
    PrivateTmp=true
    ReadWritePaths=#{data_dir}
    [Install]
    WantedBy=multi-user.target
  UNIT
  action [:create, :enable]
end

# :start never restarts a running unit. Guarded by the same condition as the unit: a
# held-back member stays inactive, and starting it would "update" on every converge.
service 'homelab-etcd' do
  action :start
  only_if { ::File.exist?("#{data_dir}/member") || ::File.exist?("#{config_dir}/join") }
end

file "#{install}/snapshot" do
  content <<~SH
    #!/bin/bash
    set -euo pipefail
    umask 077
    export ETCDCTL_ENDPOINTS="https://#{address}:2379"
    export ETCDCTL_CACERT="#{config_dir}/ca.crt"
    export ETCDCTL_CERT="#{config_dir}/admin.crt"
    export ETCDCTL_KEY="#{config_dir}/admin.key"
    repo="#{snapshot_dir}"
    exec 9>"$repo/.lock"
    flock -n 9 || exit 0
    output="$repo/$(date -u +%Y%m%dT%H%M%SZ).db"
    trap 'rm -f "$output.partial" "$output.partial.part"' EXIT
    #{install}/etcdctl snapshot save "$output.partial"
    #{install}/etcdutl snapshot status "$output.partial" >/dev/null
    mv "$output.partial" "$output"
    # Old snapshots go only after the new one saved and verified readable.
    mapfile -t snapshots < <(find "$repo" -maxdepth 1 -type f -name '????????T??????Z.db' -printf '%f\\n' | sort -r)
    for old in "${snapshots[@]:3}"; do
        rm -- "$repo/$old"
    done
  SH
  mode '0700'
end

systemd_unit 'homelab-etcd-snapshot.service' do
  content <<~UNIT
    [Unit]
    Description=Snapshot homelab shared etcd
    After=homelab-etcd.service
    [Service]
    Type=oneshot
    ExecStart=#{install}/snapshot
    User=root
    UMask=0077
    TimeoutStartSec=300
    Nice=10
  UNIT
  action :create
end

systemd_unit 'homelab-etcd-snapshot.timer' do
  content <<~UNIT
    [Unit]
    Description=Daily homelab etcd snapshot
    [Timer]
    OnCalendar=*-*-* 03:20:00 UTC
    RandomizedDelaySec=300
    Persistent=true
    [Install]
    WantedBy=timers.target
  UNIT
  action [:create, :enable, :start]
end
