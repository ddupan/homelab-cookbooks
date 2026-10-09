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
  its('addresses') { should_not include '0.0.0.0' }
  its('addresses') { should_not include '::' }
end
