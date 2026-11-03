# One-time takeover of a node deployed by Ayatori's Ansible role (deploy/ansible,
# control_plane): it ran its own node_exporter on :9100, which homelab_base now owns.
# Runs before homelab_base in the node policy so the port is free when base starts its
# exporter. Everything else the role created sits at the paths this cookbook manages.
# ponytail: drop this recipe once ayatori-dev and ayatori-prod have converged once.
service 'node-exporter' do
  action [:stop, :disable]
end

file '/etc/systemd/system/node-exporter.service' do
  action :delete
  notifies :run, 'execute[systemctl daemon-reload]', :immediately
end

execute 'systemctl daemon-reload' do
  action :nothing
end

(['/usr/local/bin/node_exporter'] + Dir.glob('/usr/local/bin/node_exporter-*.installed')).each do |f|
  file f do
    action :delete
  end
end

directory '/var/lib/node-exporter' do
  recursive true
  action :delete
end
