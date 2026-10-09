# Server certificate for dataplaneapi and gobgpd, from Bao pki/ over ACME (http-01)
# with lego, like homelab_base's spire_node_cert. pki/ needs no EAB, so the first
# converge issues it and a daily timer renews it; nothing on the node is secret.
# OpenBao's ACME certificates carry serverAuth regardless of role flags, which is
# what both APIs need. Ayatori must address the host by this DNS name: ACME issues
# no IP SANs.
unified_mode true

property :lego_version, String, default: '5.3.1'
property :server, String, default: 'https://bao.lab.ddupan.top:8200/v1/pki/acme/directory'
property :domain, String, default: lazy { "#{node['hostname']}.lab.ddupan.top" }
# http-01 on the node address only: a VIP may hold :80 on this host, and binding
# the wildcard would collide with it.
property :listen, String, required: true
property :state_dir, String, default: '/var/lib/ayatori-lb-acme'

action :install do
  release = "lego_v#{new_resource.lego_version}_linux_amd64"
  base = "https://github.com/go-acme/lego/releases/download/v#{new_resource.lego_version}"
  sums = "#{Chef::Config[:file_cache_path]}/lego_#{new_resource.lego_version}_checksums.txt"

  # Official checksum list, never a hard-coded hash. Same install as homelab_base's,
  # so both converge the same link.
  remote_file sums do
    source "#{base}/lego_#{new_resource.lego_version}_checksums.txt"
    retries 3
    retry_delay 10
  end

  remote_file "#{Chef::Config[:file_cache_path]}/#{release}.tar.gz" do
    source "#{base}/#{release}.tar.gz"
    checksum(lazy { ::File.read(sums)[/^(\h{64})\s+#{Regexp.escape(release)}\.tar\.gz$/, 1] })
    retries 3
    retry_delay 10
  end

  archive_file "#{Chef::Config[:file_cache_path]}/#{release}.tar.gz" do
    destination "/opt/lego-#{new_resource.lego_version}"
  end

  link '/usr/local/bin/lego' do
    to "/opt/lego-#{new_resource.lego_version}/lego"
  end

  directory '/etc/ayatori-lb/tls' do
    recursive true
  end
  directory new_resource.state_dir do
    mode '0700'
  end

  # Fixed paths, so the service configs never need the node's name. Both daemons
  # read the certificate only at start; try-restart leaves a stopped unit alone.
  file '/usr/local/sbin/ayatori-lb-cert-deploy' do
    content <<~SH
      #!/bin/sh
      # Managed by Cinc (homelab_loadbalancer). lego --deploy-hook: runs only after a real issue/renewal.
      # lego v5 names; set -u fails loudly if they are renamed again.
      set -eu
      install -m 0644 "$LEGO_HOOK_CERT_PATH" /etc/ayatori-lb/tls/server.crt
      install -m 0600 "$LEGO_HOOK_CERT_KEY_PATH" /etc/ayatori-lb/tls/server.key
      systemctl try-restart dataplaneapi.service gobgpd.service
    SH
    mode '0755'
  end

  # `lego run` both issues and renews (only when under 30 days left of the 60-day cert).
  file '/usr/local/sbin/ayatori-lb-cert' do
    content <<~SH
      #!/bin/sh
      # Managed by Cinc (homelab_loadbalancer).
      set -eu
      exec /usr/local/bin/lego run \\
        --accept-tos \\
        --server '#{new_resource.server}' \\
        --path '#{new_resource.state_dir}' \\
        --http \\
        --http.address '#{new_resource.listen}:80' \\
        --key-type EC256 \\
        --domains '#{new_resource.domain}' \\
        --renew-days 30 \\
        --deploy-hook /usr/local/sbin/ayatori-lb-cert-deploy
    SH
    mode '0755'
  end

  execute '/usr/local/sbin/ayatori-lb-cert' do
    creates '/etc/ayatori-lb/tls/server.crt'
  end

  systemd_unit 'ayatori-lb-cert.service' do
    content <<~UNIT
      [Unit]
      Description=Renew the Ayatori LoadBalancer server certificate (ACME, Bao pki/)
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/ayatori-lb-cert
    UNIT
    action :create
  end

  systemd_unit 'ayatori-lb-cert.timer' do
    content <<~UNIT
      [Unit]
      Description=Daily Ayatori LoadBalancer certificate renewal check

      [Timer]
      OnCalendar=daily
      RandomizedDelaySec=1h
      Persistent=true

      [Install]
      WantedBy=timers.target
    UNIT
    action [:create, :enable, :start]
  end
end
