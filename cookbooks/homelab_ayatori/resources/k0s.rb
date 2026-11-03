# k0s as an API-only controller: binary, config, and the systemd unit that
# `k0s install controller` generates. Waits until the API answers.
unified_mode true

property :version, String, required: true
property :sha256, String, required: true
property :config, String, required: true # k0s.yaml
property :install_args, String, required: true

UNIT = '/etc/systemd/system/k0scontroller.service'.freeze
INSTALL_ARGS = '/var/lib/ayatori-deploy/k0s-install-args'.freeze

action :install do
  # Restarts are immediate: everything after this resource talks to the API.
  remote_file '/usr/local/bin/k0s' do
    source "https://github.com/k0sproject/k0s/releases/download/#{new_resource.version.sub('+', '%2B')}/k0s-#{new_resource.version}-amd64"
    checksum new_resource.sha256
    mode '0755'
    retries 3
    retry_delay 10
    notifies :restart, 'service[k0scontroller]', :immediately
  end

  directory '/etc/k0s' do
    mode '0700'
  end

  file '/etc/k0s/k0s.yaml' do
    content new_resource.config
    mode '0600'
    notifies :restart, 'service[k0scontroller]', :immediately
  end

  # The start arguments live in the generated unit, whose format k0s rewrites (it
  # expands --logging, for one), so the arguments last installed decide whether to
  # regenerate it. Changing disabled components still needs `k0s reset` first: --force
  # only rewrites the unit.
  directory ::File.dirname(INSTALL_ARGS) do
    mode '0700'
  end

  args = new_resource.install_args
  execute 'k0s install controller' do
    command "/usr/local/bin/k0s install controller --force #{args}"
    not_if { ::File.exist?(UNIT) && ::File.exist?(INSTALL_ARGS) && ::File.read(INSTALL_ARGS) == args }
    notifies :restart, 'service[k0scontroller]', :immediately
  end

  file INSTALL_ARGS do
    content args
    mode '0600'
  end

  service 'k0scontroller' do
    action [:enable, :start]
  end

  # Only runs (and retries) while the API is not ready, so a healthy node reports no change.
  execute 'wait for the k0s API' do
    command '/usr/local/bin/k0s kubectl get --raw /readyz'
    not_if '/usr/local/bin/k0s kubectl get --raw /readyz'
    retries 30
    retry_delay 5
  end
end
