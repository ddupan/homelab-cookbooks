# HAProxy Data Plane API, the endpoint Ayatori writes LoadBalancer sections through.
# Reachable only over mTLS: the client CA is the environment's pki-loadbalancer-<env>
# root, so only that environment's Ayatori controller can connect. dataplaneapi still
# insists on a Basic user (it refuses to start without one); only its crypt hash is
# on the node.
unified_mode true

property :version, String, default: '3.4.3'
property :listen, String, required: true
property :port, Integer, default: 5555
property :certificate, String, required: true
property :key, String, required: true
property :client_ca, String, required: true
property :username, String, default: 'ayatori'
property :password_hash, String, required: true,
                                 callbacks: { 'must be a SHA-512 crypt hash, never a plaintext password' => lambda { |v|
                                   v.start_with?('$6$')
                                 } }

action :install do
  release = "dataplaneapi_#{new_resource.version}_linux_x86_64"
  base = "https://github.com/haproxytech/dataplaneapi/releases/download/v#{new_resource.version}"
  cache = "#{Chef::Config[:file_cache_path]}/dataplaneapi_#{new_resource.version}"

  # Official checksum list, never a hard-coded hash: the tarball is verified against it.
  remote_file "#{cache}_checksums.txt" do
    source "#{base}/checksums.txt"
    retries 3
    retry_delay 10
  end

  remote_file "#{cache}.tar.gz" do
    source "#{base}/#{release}.tar.gz"
    checksum(lazy { ::File.read("#{cache}_checksums.txt")[/^(\h{64})\s+#{Regexp.escape(release)}\.tar\.gz$/, 1] })
    retries 3
    retry_delay 10
  end

  archive_file "#{cache}.tar.gz" do
    destination "/opt/dataplaneapi-#{new_resource.version}"
  end

  link '/usr/local/bin/dataplaneapi' do
    to "/opt/dataplaneapi-#{new_resource.version}/dataplaneapi"
    notifies :restart, 'service[dataplaneapi]'
  end

  directory '/etc/dataplaneapi'
  directory '/var/lib/dataplaneapi' do
    mode '0700'
  end

  # dataplaneapi normalises and rewrites the file it was started with, which would
  # show up as drift on every converge. Chef owns this source; ExecStartPre copies it
  # to the runtime copy the daemon is allowed to rewrite.
  file '/etc/dataplaneapi/dataplaneapi.yml' do
    content <<~YAML
      # Managed by Cinc (homelab_loadbalancer)
      config_version: 2
      name: #{node['hostname']}
      dataplaneapi:
        scheme: [https]
        tls:
          tls_host: #{new_resource.listen}
          tls_port: #{new_resource.port}
          tls_certificate: #{new_resource.certificate}
          tls_key: #{new_resource.key}
          tls_ca: #{new_resource.client_ca}
        user:
          - name: #{new_resource.username}
            password: '#{new_resource.password_hash}'
            insecure: false
        transaction:
          transaction_dir: /var/lib/dataplaneapi/transactions
          backups_dir: /var/lib/dataplaneapi/backups
        resources:
          maps_dir: /var/lib/dataplaneapi/maps
          ssl_certs_dir: /var/lib/dataplaneapi/ssl
          general_storage_dir: /var/lib/dataplaneapi/general
          spoe_dir: /var/lib/dataplaneapi/spoe
          dataplane_storage_dir: /var/lib/dataplaneapi/storage
      haproxy:
        config_file: /etc/haproxy/haproxy.cfg
        haproxy_bin: /usr/sbin/haproxy
        master_worker_mode: true
        master_runtime: /run/haproxy-master.sock
        reload:
          reload_strategy: systemd
          service_name: haproxy.service
          reload_delay: 5
          # Its own check runs haproxy -c on haproxy.cfg alone, which has no global,
          # defaults or resolvers; validate the way the service loads it.
          validate_files_before:
            - /etc/haproxy/base.cfg
    YAML
    mode '0600'
    notifies :restart, 'service[dataplaneapi]'
  end

  systemd_unit 'dataplaneapi.service' do
    content <<~UNIT
      [Unit]
      Description=HAProxy Data Plane API
      After=haproxy.service network-online.target
      Wants=network-online.target

      [Service]
      ExecStartPre=/usr/bin/install -m 0600 /etc/dataplaneapi/dataplaneapi.yml /var/lib/dataplaneapi/dataplaneapi.yml
      ExecStart=/usr/local/bin/dataplaneapi -f /var/lib/dataplaneapi/dataplaneapi.yml
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
    UNIT
    action [:create, :enable]
    notifies :restart, 'service[dataplaneapi]'
  end

  service 'dataplaneapi' do
    action :start
  end
end
