# The node certificate SPIRE's x509pop attestor checks, from Bao's dedicated
# pki-spire-nodes CA over ACME (http-01), with lego like the repo's other ACME
# roles. First enrollment needs a one-time EAB, which homelab-infra's enrollment
# step passes in LEGO_EAB_KID/LEGO_EAB_HMAC when it runs the script once; renewals
# (this timer) use the registered account and need no secret at all.
unified_mode true

property :lego_version, String, default: '5.3.1'
property :server, String, default: 'https://bao.lab.ddupan.top:8200/v1/pki-spire-nodes/roles/node/acme/directory'
# Convention: a node's lab DNS name is <hostname>.lab.ddupan.top. Enrollment
# checks that it resolves to the node before minting an EAB.
property :domain, String, default: lazy { "#{node['hostname']}.lab.ddupan.top" }
property :state_dir, String, default: '/var/lib/spire-node-acme'

action :install do
  homelab_base_verified_release '/usr/local/bin/lego' do
    url_base "https://github.com/go-acme/lego/releases/download/v#{new_resource.lego_version}"
    tarball "lego_v#{new_resource.lego_version}_linux_amd64.tar.gz"
    checksums "lego_#{new_resource.lego_version}_checksums.txt"
    install_dir "/opt/lego-#{new_resource.lego_version}"
    binary 'lego'
  end

  directory '/etc/spire-agent'
  directory new_resource.state_dir do
    mode '0700'
  end

  # Copies to a fixed path, so the agent config never needs the node's name.
  file '/usr/local/sbin/spire-node-cert-deploy' do
    content <<~SH
      #!/bin/sh
      # Managed by Cinc (homelab_base). lego --deploy-hook: runs only after a real issue/renewal.
      # lego v5 names (v4's LEGO_CERT_PATH is empty under v5); set -u fails loudly if renamed again.
      set -eu
      install -m 0644 "$LEGO_HOOK_CERT_PATH" /etc/spire-agent/node.crt
      install -m 0600 "$LEGO_HOOK_CERT_KEY_PATH" /etc/spire-agent/node.key
    SH
    mode '0755'
  end

  # `lego run` both issues and renews (only when under 30 days left). --enable-cn:
  # lego v5 leaves CN out by default, and the SPIRE node alias matches on it.
  file '/usr/local/sbin/spire-node-cert' do
    content <<~SH
      #!/bin/sh
      # Managed by Cinc (homelab_base). Enrollment runs this once with
      # LEGO_EAB_KID/LEGO_EAB_HMAC set; the timer runs it without.
      set -eu
      exec /usr/local/bin/lego run \\
        --accept-tos \\
        --server '#{new_resource.server}' \\
        --path '#{new_resource.state_dir}' \\
        --http \\
        --enable-cn \\
        --key-type EC256 \\
        --domains '#{new_resource.domain}' \\
        --renew-days 30 \\
        --deploy-hook /usr/local/sbin/spire-node-cert-deploy \\
        ${LEGO_EAB_KID:+--eab}
    SH
    mode '0755'
  end

  systemd_unit 'spire-node-cert.service' do
    content <<~UNIT
      [Unit]
      Description=Renew the SPIRE node certificate (ACME, Bao pki-spire-nodes)
      # Not enrolled yet: there is no ACME account to renew with.
      ConditionPathExists=/etc/spire-agent/node.crt
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/spire-node-cert
    UNIT
    action :create
  end

  systemd_unit 'spire-node-cert.timer' do
    content <<~UNIT
      [Unit]
      Description=Daily SPIRE node certificate renewal check

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
