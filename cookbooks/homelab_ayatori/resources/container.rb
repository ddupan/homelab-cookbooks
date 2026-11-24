require 'digest'

# A podman quadlet on the host network with a read-only root. Images are pinned by
# digest, so "present" is "current": nothing is pulled once the image exists.
unified_mode true

property :container_name, String, name_property: true
property :image, String, required: true,
                         callbacks: { 'must be pinned by digest' => ->(v) { v.include?('@sha256:') } }
property :user, Integer, required: true
property :exec, Array, default: []
property :env, Hash, default: {}
property :volumes, Array, default: []
property :memory, String, required: true
property :entrypoint, [String, nil]
property :capabilities, Array, default: [] # added back after DropCapability=ALL
# Files the container reads only at start (its kubeconfig): their digest goes into the
# quadlet, so a change restarts the container. Certificates are not listed: client-go
# reloads them by itself.
property :restart_on, Array, default: []

action :create do
  name = new_resource.container_name

  execute "podman pull #{new_resource.image}" do
    not_if "podman image exists #{new_resource.image}"
    retries 3
    retry_delay 15
  end

  inputs = new_resource.restart_on.map do |f|
    "# #{f}: #{::File.exist?(f) ? Digest::SHA256.file(f).hexdigest : 'absent'}"
  end
  lines = [
    '# Managed by Cinc (homelab_ayatori)',
    *inputs,
    '[Unit]',
    "Description=#{name}",
    'After=k0scontroller.service network-online.target',
    'Wants=network-online.target',
    '',
    '[Container]',
    "Image=#{new_resource.image}",
  ]
  lines << "PodmanArgs=--entrypoint=#{new_resource.entrypoint}" if new_resource.entrypoint
  lines += [
    'Network=host',
    'ReadOnly=true',
    'Tmpfs=/tmp',
    "User=#{new_resource.user}",
    'NoNewPrivileges=true',
    'DropCapability=ALL',
  ]
  lines << "AddCapability=#{new_resource.capabilities.join(' ')}" unless new_resource.capabilities.empty?
  lines += new_resource.volumes.map { |v| "Volume=#{v}" }
  lines += new_resource.env.sort.map { |k, v| "Environment=#{k}=#{v}" }
  lines << "Exec=#{new_resource.exec.join(' ')}" unless new_resource.exec.empty?
  lines += [
    '',
    '[Service]',
    'Restart=on-failure',
    'RestartSec=10',
    "MemoryMax=#{new_resource.memory}",
    '',
    '[Install]',
    'WantedBy=multi-user.target',
  ]

  execute "#{name}: systemctl daemon-reload" do
    command 'systemctl daemon-reload'
    action :nothing
  end

  # Declared before the quadlet file so its immediate :restart runs right after the file changes.
  # In unified mode a notification to a resource declared later waits until that resource has run:
  # with only the :start below, a first install ran start and then restart while the container was
  # still starting, and systemd cancelled the start job ("a fatal signal was delivered to the
  # control process"). A start that finds the unit activating waits for that job instead.
  service name do
    action :nothing
  end

  file "/etc/containers/systemd/#{name}.container" do
    content "#{lines.join("\n")}\n"
    mode '0644'
    notifies :run, "execute[#{name}: systemctl daemon-reload]", :immediately
    notifies :restart, "service[#{name}]", :immediately
  end

  # Quadlet units are generated: enabling them is the [Install] section's job.
  # A unit between Restart=on-failure attempts (SubState auto-restart) is already being started by
  # systemd; starting it again only reports a change on every run while the container crash-loops
  # (Kitchen: the manager cannot reach Bao or PostgreSQL). A config change still restarts it: the
  # quadlet file notifies before this guard is evaluated, and systemd picks up the regenerated unit
  # on its next attempt either way.
  service name do
    action :start
    not_if "systemctl show -p SubState --value #{name}.service | grep -qx auto-restart"
  end
end
