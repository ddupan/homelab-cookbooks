# prometheus-node-exporter from the distro, textfile collector on. vmagent
# scrapes it over the LAN.
unified_mode true

# In a container these only see the host's hardware (or nothing): host disks,
# sensors, CPU frequency, the host's ZFS ARC. The host's own node_exporter
# already reports them; from the guest they are wrong or empty series.
CONTAINER_DISABLED = %w(
  bcache cpufreq diskstats edac fibrechannel hwmon infiniband mdadm nvme
  powersupplyclass rapl tapestats thermal_zone zfs
).freeze

property :listen, String, default: ':9100'
property :textfile_dir, String, default: '/var/lib/prometheus/node-exporter'
property :disabled_collectors, Array,
         default: lazy {
           virt = node['virtualization'] || {}
           virt['role'] == 'guest' && %w(lxc lxd docker podman).include?(virt['system']) ? CONTAINER_DISABLED : []
         }

action :install do
  directory new_resource.textfile_dir do
    recursive true
  end

  apt_package 'prometheus-node-exporter' do
    options '--no-install-recommends -o Dpkg::Options::=--force-confold'
    retries 3
    retry_delay 5
  end

  args = ["--web.listen-address=#{new_resource.listen}",
          "--collector.textfile.directory=#{new_resource.textfile_dir}"] +
         new_resource.disabled_collectors.map { |c| "--no-collector.#{c}" }

  file '/etc/default/prometheus-node-exporter' do
    content "# Managed by Cinc (homelab_base)\nARGS=\"#{args.join(' ')}\"\n"
    mode '0644'
    notifies :restart, 'service[prometheus-node-exporter]'
  end

  service 'prometheus-node-exporter' do
    action [:enable, :start]
  end
end
