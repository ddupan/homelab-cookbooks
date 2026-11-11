# Runs inside the converged container (Test Kitchen + Cinc Auditor).
describe systemd_service('ayatori-compute-agent') do
  it { should be_enabled }
  it { should be_running }
end

describe systemd_service('ayatori-imds') do
  it { should be_enabled }
  it { should be_running }
end

# The stand-in agent reached the system libvirt through its unit, then wrote into its
# state directory under ProtectSystem=full.
describe file('/var/lib/ayatori/compute-agent/started') do
  it { should exist }
end

describe file('/etc/ayatori/compute-agent') do
  its('mode') { should cmp '0700' }
end

describe json('/etc/ayatori/compute-agent.yaml') do
  its('credentialsDir') { should eq '/etc/ayatori/compute-agent' }
  its(%w(nodeLabels topology.kubernetes.io/zone)) { should eq 'test' }
end
