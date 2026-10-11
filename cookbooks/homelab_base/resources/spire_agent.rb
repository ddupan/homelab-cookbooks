# SPIRE agent for a host outside any Kubernetes cluster, attesting with x509pop.
# The node certificate comes from spire_node_cert (ACME, Bao pki-spire-nodes) at a
# fixed path; this resource never touches that key material.
unified_mode true

property :version, String, default: '1.15.3'
property :server_address, String, required: true
property :trust_domain, String, required: true
# Public bundle, dropped by enrollment; only bootstraps, the agent keeps it current.
property :bootstrap_bundle, String, default: '/etc/spire-agent/bootstrap-bundle.pem'

action :install do
  release = "spire-#{new_resource.version}-linux-amd64-musl"

  homelab_base_verified_release '/usr/local/bin/spire-agent' do
    url_base "https://github.com/spiffe/spire/releases/download/v#{new_resource.version}"
    tarball "#{release}.tar.gz"
    checksums "#{release}_sha256sum.txt"
    install_dir "/opt/#{release}"
    binary "spire-#{new_resource.version}/bin/spire-agent"
    notifies :restart, 'service[spire-agent]'
  end

  directory '/var/lib/spire-agent' do
    mode '0700'
  end

  file '/etc/spire-agent/agent.conf' do
    content <<~HCL
      # Managed by Cinc (homelab_base)
      agent {
        data_dir          = "/var/lib/spire-agent"
        log_level         = "INFO"
        server_address    = "#{new_resource.server_address}"
        server_port       = "8081"
        # Same path as the laptop's agent, so local tooling works on every host.
        socket_path       = "/run/spire/agent-sockets/spire-agent.sock"
        trust_bundle_path = "#{new_resource.bootstrap_bundle}"
        trust_domain      = "#{new_resource.trust_domain}"
      }

      plugins {
        KeyManager "disk" {
          plugin_data { directory = "/var/lib/spire-agent" }
        }
        # Unlike join_token, x509pop can re-attest: downtime longer than the SVID
        # lifetime or a lost data_dir just attests again with the node certificate.
        NodeAttestor "x509pop" {
          plugin_data {
            private_key_path = "/etc/spire-agent/node.key"
            certificate_path = "/etc/spire-agent/node.crt"
          }
        }
        WorkloadAttestor "unix" {
          plugin_data {}
        }
      }
    HCL
    notifies :restart, 'service[spire-agent]'
  end

  systemd_unit 'spire-agent.service' do
    content <<~UNIT
      [Unit]
      Description=SPIRE Agent
      After=network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/spire-agent run -config /etc/spire-agent/agent.conf
      RuntimeDirectory=spire/agent-sockets
      RuntimeDirectoryPreserve=yes
      Restart=on-failure
      RestartSec=10

      [Install]
      WantedBy=multi-user.target
    UNIT
    action [:create, :enable]
    notifies :restart, 'service[spire-agent]'
  end

  service 'spire-agent' do
    action :start
    # Not enrolled yet (no node certificate): the agent could only crash-loop, and
    # every converge would "start" it again. Enrollment always precedes the run.
    only_if { ::File.exist?('/etc/spire-agent/node.crt') }
  end
end
