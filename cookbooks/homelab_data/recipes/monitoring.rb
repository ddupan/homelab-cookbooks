# Shared data maintenance metrics (etcd snapshots, certificate expiry, pgBackRest full
# backups), formerly homelab-infra's shared-data-monitoring play. The laptop half of that
# play stays on Ansible and downloads files/default/collect.py from this repo's tag,
# so the collector has one source.
#
# Port 9109, job shared-data-maintenance: vmagent's scrape config and alert rules in
# homelab-infra key on that job, so this keeps its own exporter rather than writing into
# homelab_base's textfile directory on 9100.
data = node['homelab_data']
root = '/opt/homelab-data-monitoring'
config = '/etc/homelab-data-monitoring/config.json'
output_dir = '/var/lib/homelab-data-monitoring'
collect = "/usr/bin/python3 #{root}/collect.py --config #{config} --output #{output_dir}/health.prom"

package %w(python3 openssl prometheus-node-exporter) do
  options '--no-install-recommends -o Dpkg::Options::=--force-confold'
  retries 3
  retry_delay 5
end

[root, File.dirname(config), output_dir].each do |dir|
  directory dir do
    mode '0755'
  end
end

cookbook_file "#{root}/collect.py" do
  source 'collect.py'
  mode '0755'
end

certificates = %w(server peer admin gateway ca).map { |n| { 'name' => "etcd-#{n}", 'path' => "/etc/homelab-etcd/#{n}.crt" } }
if data['postgresql_prod']
  certificates += %w(server etcd ca).map { |n| { 'name' => "pg-prod-#{n}", 'path' => "/etc/homelab-postgresql/prod/#{n}.crt" } }
end

file config do
  content JSON.pretty_generate(
    'snapshot_dir' => '/var/backups/homelab-etcd',
    'dev' => false,
    'repository' => data['pgbackrest_repository'],
    'renewal_units' => [],
    'certificates' => certificates,
    # homelab_data::etcd never restarts etcd; this is how a pending restart shows.
    'restart_units' => if data['etcd']['members'].to_h.key?(node['hostname'])
                         [{ 'unit' => 'homelab-etcd',
                            'paths' => %w(/etc/homelab-etcd/etcd.yml /etc/systemd/system/homelab-etcd.service
                                          /opt/homelab-etcd/etcd) }]
                       else
                         []
                       end
  ) + "\n"
  mode '0644'
end

# Read-only checks run as root: they read snapshot metadata and switch to pgbackup.
# Writes are confined to the textfile directory.
systemd_unit 'homelab-data-collect.service' do
  content <<~UNIT
    [Unit]
    Description=Read-only shared data maintenance checks
    [Service]
    Type=oneshot
    ExecStart=#{collect}
    Environment=LC_ALL=C
    TimeoutStartSec=50
    UMask=0022
    ProtectSystem=strict
    ReadWritePaths=#{output_dir}
    PrivateTmp=true
    MemoryMax=96M
    Nice=10
  UNIT
  action :create
end

systemd_unit 'homelab-data-collect.timer' do
  content <<~UNIT
    [Unit]
    Description=Collect shared data maintenance metrics every minute
    [Timer]
    OnBootSec=30s
    OnUnitActiveSec=60s
    AccuracySec=5s
    [Install]
    WantedBy=timers.target
  UNIT
  action [:create, :enable, :start]
end

# The distro node_exporter (homelab_base installs it for :9100) as a second, textfile-only
# instance. Node address only: vmagent reaches it there and nothing else needs it.
systemd_unit 'homelab-data-exporter.service' do
  content <<~UNIT
    [Unit]
    Description=Shared data textfile metrics
    After=network-online.target
    Wants=network-online.target
    [Service]
    DynamicUser=true
    ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=#{node['ipaddress']}:9109 \\
      --collector.disable-defaults --collector.textfile \\
      --collector.textfile.directory=#{output_dir} --web.disable-exporter-metrics
    Restart=on-failure
    NoNewPrivileges=true
    ProtectSystem=strict
    ProtectHome=true
    PrivateTmp=true
    MemoryMax=64M
    [Install]
    WantedBy=multi-user.target
  UNIT
  action [:create, :enable, :start]
  notifies :restart, 'service[homelab-data-exporter]'
end

service 'homelab-data-exporter' do
  action :nothing
end

# Left behind by the Ansible play, which downloaded node_exporter from GitHub.
directory "#{root}/node_exporter-1.9.1.linux-amd64" do
  recursive true
  action :delete
end

file "#{root}/node_exporter.tar.gz" do
  action :delete
end
