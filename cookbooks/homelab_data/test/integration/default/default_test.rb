# Runs inside the converged container (Test Kitchen + Cinc Auditor).
describe systemd_service('homelab-data-exporter') do
  it { should be_enabled }
  it { should be_running }
end

describe systemd_service('homelab-data-collect.timer') do
  it { should be_enabled }
  it { should be_running }
end

# One collection end to end, read back through the exporter. The container has no etcd,
# so the checks themselves fail; the collection timestamp proves the chain works.
describe command("systemctl start homelab-data-collect.service && python3 -c \"import urllib.request; print(urllib.request.urlopen('http://#{interface('eth0').ipv4_addresses.first}:9109/metrics').read().decode())\"") do
  its('exit_status') { should eq 0 }
  its('stdout') { should match(/^homelab_data_collection_timestamp_seconds /) }
  # The textfile collector pads label sets per metric (backup="" here), hence [^}]*.
  its('stdout') { should match(/^homelab_data_check_success\{[^}]*certificate="etcd-ca"[^}]*\} 0$/) }
end

# etcd member: installed and configured, but held back until it has data or a join marker.
describe command('/opt/homelab-etcd/etcd --version') do
  its('stdout') { should match(/etcd Version: 3\.7\.2/) }
end

describe systemd_service('homelab-etcd') do
  it { should be_enabled }
  it { should_not be_running }
end

describe file('/etc/homelab-etcd/etcd.yml') do
  its('group') { should eq 'homelab-etcd' }
  its('mode') { should cmp '0640' }
  its('content') { should match(%r{^initial-cluster: "dokken=https://127.0.0.1:2380"$}) }
end

describe systemd_service('homelab-etcd-cert.timer') do
  it { should be_enabled }
end

describe json('/etc/homelab-data-monitoring/config.json') do
  its(['restart_units', 0, 'unit']) { should eq 'homelab-etcd' }
end
