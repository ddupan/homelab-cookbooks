# The deployer's part in Kitchen: an independent backup volume (a tmpfs here) and a
# stand-in for Bao's public CA. Test material only.
directory '/var/backups/ayatori'

mount '/var/backups/ayatori' do
  device 'tmpfs'
  fstype 'tmpfs'
  options 'size=64m'
  action :mount
end

directory '/etc/ayatori-test'

# curl: the suite sends anonymous requests to the apiserver (kubectl would prompt for a user).
package %w(openssl curl)

execute 'test CA' do
  command 'openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 ' \
          '-subj /CN=test-ca -keyout /etc/ayatori-test/ca.key -out /etc/ayatori-test/ca.pem'
  creates '/etc/ayatori-test/ca.pem'
end

# Podman inside the Kitchen container: overlay on overlay does not work, vfs does.
directory '/etc/containers'

file '/etc/containers/storage.conf' do
  content <<~TOML
    [storage]
    driver = "vfs"
    runroot = "/run/containers/storage"
    graphroot = "/var/lib/containers/storage"
  TOML
end

# Pull through a mirror when Kitchen runs in CI. Images are pinned by digest, so the
# mirror cannot hand out anything else.
mirror = node.dig('ayatori_test', 'registry_mirror').to_s
directory '/etc/containers/registries.conf.d' do
  recursive true
end

file '/etc/containers/registries.conf.d/50-kitchen-mirror.conf' do
  content(%w(docker.io ghcr.io registry.k8s.io).map do |registry|
    <<~TOML
      [[registry]]
      prefix = "#{registry}"
      location = "#{registry}"
      [[registry.mirror]]
      location = "#{mirror}"
    TOML
  end.join("\n"))
  action mirror.empty? ? :delete : :create
end
