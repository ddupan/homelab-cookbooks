# Runs inside the converged container (Test Kitchen + Cinc Auditor).
describe file('/usr/local/share/ca-certificates/ddupan-internal-ca.crt') do
  its('content') { should include 'BEGIN CERTIFICATE' }
end

describe file('/etc/ssl/certs/ca-certificates.crt') do
  its('content') { should include file('/usr/local/share/ca-certificates/ddupan-internal-ca.crt').content.lines[1] }
end

describe command('install -d -m 0755 /run/sshd && /usr/sbin/sshd -T') do
  its('stdout') { should match %r{^trustedusercakeys /etc/ssh/openbao_user_ca.pub$} }
end

describe service('prometheus-node-exporter') do
  it { should be_enabled }
  it { should be_running }
end

describe port(9100) do
  it { should be_listening }
end

# Kitchen runs in Docker, i.e. a container guest: host-hardware collectors are off.
describe http('http://127.0.0.1:9100/metrics') do
  its('body') { should match(/^node_textfile_scrape_error/) }
  its('body') { should_not match(/^node_hwmon_/) }
end

describe systemd_service('homelab-cinc-drift.timer') do
  it { should be_enabled }
  it { should be_running }
end

# Written by the run report at the end of the converge Kitchen just did.
describe file('/var/lib/prometheus/node-exporter/cinc_apply.prom') do
  its('content') { should match(/^homelab_cinc_last_run_success\{mode="apply"\} 1$/) }
end

# Not enrolled in Kitchen (no ACME node certificate): installed and enabled, not started.
describe file('/usr/local/bin/spire-agent') do
  it { should be_symlink }
end

describe command('/usr/local/bin/spire-agent --version') do
  its('stderr') { should match(/1\.15\.3/) }
end

describe systemd_service('spire-agent') do
  it { should be_enabled }
  it { should_not be_running }
end

# Enrollment (one-time EAB from homelab-infra) never runs in a converge, so a test
# run cannot register this container with Bao or SPIRE.
describe file('/etc/spire-agent/node.crt') do
  it { should_not exist }
end

describe command('/usr/local/bin/lego --version') do
  its('stdout') { should match(/5\.3\.1/) }
end

describe systemd_service('spire-node-cert.timer') do
  it { should be_enabled }
end
