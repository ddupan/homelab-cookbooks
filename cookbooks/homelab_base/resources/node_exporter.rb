# prometheus-node-exporter from the distro, bound to one address with the
# textfile collector on. vmagent scrapes it over the LAN.
unified_mode true

property :listen, String, name_property: true,
                          callbacks: { 'must bind a specific address, never all interfaces' => lambda { |v|
                            !v.start_with?('0.0.0.0:', ':', '[::]:')
                          } }
property :textfile_dir, String, default: '/var/lib/prometheus/node-exporter'

action :install do
  # Written BEFORE the package: its postinst starts the service, and without this
  # file that first start would listen on 0.0.0.0:9100.
  file '/etc/default/prometheus-node-exporter' do
    content "# Managed by Cinc (homelab_base)\n" \
            "ARGS=\"--web.listen-address=#{new_resource.listen} " \
            "--collector.textfile.directory=#{new_resource.textfile_dir}\"\n"
    mode '0644'
    notifies :restart, 'service[prometheus-node-exporter]'
  end

  directory new_resource.textfile_dir do
    recursive true
  end

  apt_package 'prometheus-node-exporter' do
    # confold: keep the defaults file above instead of the package's copy.
    options '--no-install-recommends -o Dpkg::Options::=--force-confold'
    retries 3
    retry_delay 5
  end

  service 'prometheus-node-exporter' do
    action [:enable, :start]
  end
end
