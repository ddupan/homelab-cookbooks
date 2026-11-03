require 'openssl'
require 'securerandom'
require 'base64'

# A client certificate identity of the control plane (Ayatori ADR-0021): a directory
# the client-credentials container writes the key, certificate and kubeconfig into.
#
# :prepare starts a first issuance when the certificate is missing or close to expiry
# (renewal normally happens on its own at 70–90% of the lifetime): a 15-minute bootstrap
# token, written into bootstrap-kubeconfig, which only root can read.
# :approve, after the client-credentials container is running, checks that the CSR
# made with that token asks for exactly this identity and approves it as admin.
unified_mode true

property :user_name, String, name_property: true
property :uid, Integer, required: true
property :dir, String, required: true
property :server, String, required: true # https://<api>:6443
property :image, String                  # for :approve: the client-credentials image

BOOTSTRAP_GROUP = 'system:bootstrappers:ayatori'.freeze
RENEW_BEFORE = 7 * 86_400

action_class do
  def issuance_needed?
    cert = ::File.join(new_resource.dir, 'client.pem')
    return true unless ::File.exist?(cert)
    OpenSSL::X509::Certificate.new(::File.read(cert)).not_after < Time.now + RENEW_BEFORE
  rescue OpenSSL::X509::CertificateError
    true
  end

  def pending
    node.run_state['homelab_ayatori_bootstrap'] ||= {}
  end
end

action :prepare do
  directory new_resource.dir do
    owner new_resource.uid
    group new_resource.uid
    mode '0500'
    recursive true
  end

  if issuance_needed?
    id = SecureRandom.alphanumeric(6).downcase
    secret = SecureRandom.alphanumeric(16).downcase
    pending[new_resource.user_name] = id

    execute "bootstrap token for #{new_resource.user_name}" do
      command '/usr/local/bin/k0s kubectl apply -f -'
      input <<~YAML
        apiVersion: v1
        kind: Secret
        metadata: {namespace: kube-system, name: bootstrap-token-#{id}}
        type: bootstrap.kubernetes.io/token
        stringData:
          token-id: "#{id}"
          token-secret: "#{secret}"
          expiration: "#{(Time.now.utc + 900).strftime('%Y-%m-%dT%H:%M:%SZ')}"
          usage-bootstrap-authentication: "true"
          auth-extra-groups: #{BOOTSTRAP_GROUP}
      YAML
      sensitive true
    end

    ca = ::File.exist?('/var/lib/k0s/pki/ca.crt') ? Base64.strict_encode64(::File.read('/var/lib/k0s/pki/ca.crt')) : ''
    file ::File.join(new_resource.dir, 'bootstrap-kubeconfig') do
      content <<~YAML
        apiVersion: v1
        kind: Config
        clusters:
        - name: ayatori
          cluster:
            server: #{new_resource.server}
            certificate-authority-data: #{ca}
        users:
        - name: bootstrap
          user:
            token: #{id}.#{secret}
        contexts:
        - name: default
          context: {cluster: ayatori, user: bootstrap}
        current-context: default
      YAML
      owner 'root'
      group 'root'
      mode '0400'
      sensitive true
    end
  end
end

action :approve do
  id = pending[new_resource.user_name]
  return if id.nil?

  # The checks live in Ayatori (internal/infra/clientcert.ApproveBootstrap).
  execute "approve the first certificate of #{new_resource.user_name}" do
    command ['podman', 'run', '--rm', '--network', 'host', '--user', '0', '--entrypoint', '/client-credentials',
             '-v', '/var/lib/k0s/pki/admin.conf:/admin.conf:ro', new_resource.image,
             'approve-bootstrap', '--kubeconfig', '/admin.conf', '--token-id', id, '--user', new_resource.user_name]
  end

  cert = ::File.join(new_resource.dir, 'client.pem')
  execute "wait for the certificate of #{new_resource.user_name}" do
    command "test -s #{cert}"
    retries 60
    retry_delay 2
  end
end
