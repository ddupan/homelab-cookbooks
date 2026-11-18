# HAProxy Data Plane API, the endpoint the host's own Ayatori agent converges HAProxy
# through (Ayatori ADR-0022): plain HTTP on loopback only, one user, the agent's. Its
# password is generated on this host and never leaves it; the file is readable by the
# agent alone. Nothing listens on the node address: the control plane never connects.
unified_mode true

# renovate: datasource=github-releases depName=haproxytech/dataplaneapi
property :version, String, default: '3.4.3'
property :local_port, Integer, default: 5556
property :local_user, String, default: 'lb-agent'
property :local_password_file, String, required: true

action :install do
  homelab_base_verified_release '/usr/local/bin/dataplaneapi' do
    url_base "https://github.com/haproxytech/dataplaneapi/releases/download/v#{new_resource.version}"
    tarball "dataplaneapi_#{new_resource.version}_linux_x86_64.tar.gz"
    # Upstream's list is a bare checksums.txt; the URL is per version, so the cached
    # copy is refetched when the version changes.
    checksums 'checksums.txt'
    install_dir "/opt/dataplaneapi-#{new_resource.version}"
    binary 'dataplaneapi'
    notifies :restart, 'service[dataplaneapi]'
  end

  directory '/etc/dataplaneapi'
  directory '/var/lib/dataplaneapi' do
    mode '0700'
  end

  # dataplaneapi normalises and rewrites the file it was started with, which would
  # show up as drift on every converge. Chef owns this source; ExecStartPre copies it
  # to the runtime copy the daemon is allowed to rewrite.
  local_password_file = new_resource.local_password_file
  # The agent resource creates the file earlier in the same run. A why-run creates
  # nothing, so on the run that enables it the file is not there yet: render a
  # placeholder rather than failing (the real run never sees it).
  local_password = -> { ::File.exist?(local_password_file) ? ::File.read(local_password_file).strip : '(created on apply)' }
  file '/etc/dataplaneapi/dataplaneapi.yml' do
    # Lazy: the local password file is created on this run, before this resource.
    content(lazy { <<~YAML })
      # Managed by Cinc (homelab_loadbalancer)
      config_version: 2
      name: #{node['hostname']}
      dataplaneapi:
        scheme: [http]
        host: 127.0.0.1
        port: #{new_resource.local_port}
        user:
          - name: #{new_resource.local_user}
            password: '#{local_password.call}'
            insecure: true
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
          # The systemd strategy hard-codes `sudo -n systemctl ...`, and the LXC
          # template has no sudo; dataplaneapi runs as root, so call systemctl directly.
          reload_strategy: custom
          reload_cmd: systemctl reload haproxy.service
          restart_cmd: systemctl restart haproxy.service
          status_cmd: systemctl is-active haproxy.service
          reload_delay: 5
          # Its own check runs haproxy -c on haproxy.cfg alone, which has no global,
          # defaults or resolvers; validate the way the service loads it.
          validate_files_before:
            - /etc/haproxy/base.cfg
    YAML
    mode '0600'
    # Always: the diff shows the OLD content too, so dropping the local user printed its
    # live password into a PR's why-run comment (2026-11-04).
    sensitive true
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
