# Runs inside the converged container (Test Kitchen + Cinc Auditor). Calls the APIs
# the way the Ayatori controller does: mTLS with a client certificate from the
# environment's CA, plus the Basic user.
address = sys_info.ip_address.strip
tls = '--cacert /etc/lb-test/server-ca.pem --cert /etc/lb-test/client.crt --key /etc/lb-test/client.key'
api = "https://#{address}:5555/v3/services/haproxy"
gobgp = "/usr/local/bin/gobgp -u #{address} --tls --tls-ca-file /etc/lb-test/server-ca.pem"

%w(haproxy dataplaneapi gobgpd).each do |unit|
  describe systemd_service(unit) do
    it { should be_enabled }
    it { should be_running }
  end
end

describe kernel_parameter('net.ipv4.ip_nonlocal_bind') do
  its('value') { should eq 1 }
end

describe command("curl -sf -o /dev/null -w '%{http_code}' #{tls} -u ayatori:test-only #{api}/configuration/version") do
  its('stdout') { should eq '200' }
end

# dataplaneapi v3.4.3 skips the Basic check once the client certificate verifies:
# mTLS against the environment's CA is the real gate, the user only lets it start.
# If an upgrade starts enforcing Basic, this fails and the password becomes load-bearing.
describe command("curl -s -o /dev/null -w '%{http_code}' #{tls} -u ayatori:wrong #{api}/configuration/version") do
  its('stdout') { should eq '200' }
end

# No client certificate, or one from another CA (another environment): refused in TLS.
describe command("curl -s --cacert /etc/lb-test/server-ca.pem -u ayatori:test-only #{api}/configuration/version") do
  its('exit_status') { should_not eq 0 }
end

describe command('curl -s --cacert /etc/lb-test/server-ca.pem --cert /etc/lb-test/other.crt ' \
                 "--key /etc/lb-test/other.key -u ayatori:test-only #{api}/configuration/version") do
  its('exit_status') { should_not eq 0 }
end

# What Ayatori does: a frontend bound to a VIP that is not on this host, its backend
# with a server that resolves through the base config's resolvers, in one transaction.
# The reload validates base.cfg + haproxy.cfg together and saves server state.
describe command(<<~SH) do
  set -e
  version=$(curl -sf #{tls} -u ayatori:test-only #{api}/configuration/version)
  tx=$(curl -sf #{tls} -u ayatori:test-only -X POST "#{api}/transactions?version=$version" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
  curl -sf #{tls} -u ayatori:test-only -H 'Content-Type: application/json' -X POST \\
    "#{api}/configuration/backends?transaction_id=$tx&full_section=true" \\
    -d '{"name":"lb_test_6443_backend","mode":"tcp","servers":{"s":{"name":"s","address":"api.example.invalid","port":6443,"check":"enabled","init-addr":"none","resolvers":"lan"}}}' >/dev/null
  curl -sf #{tls} -u ayatori:test-only -H 'Content-Type: application/json' -X POST \\
    "#{api}/configuration/frontends?transaction_id=$tx&full_section=true" \\
    -d '{"name":"lb_test_6443","mode":"tcp","default_backend":"lb_test_6443_backend","binds":{"vip":{"name":"vip","address":"10.62.0.9","port":6443}}}' >/dev/null
  curl -sf #{tls} -u ayatori:test-only -X PUT "#{api}/transactions/$tx" >/dev/null
  for i in $(seq 30); do
    status=$(curl -sf #{tls} -u ayatori:test-only #{api}/reloads | grep -o '"status":"[a-z_]*"' | tail -1)
    case "$status" in *succeeded*) break ;; *failed*) echo "$status"; exit 1 ;; esac
    sleep 1
  done
  echo "$status"
SH
  its('stdout') { should include 'succeeded' }
  its('exit_status') { should eq 0 }
end

describe port(6443) do
  it { should be_listening }
  its('addresses') { should include '10.62.0.9' }
end

describe file('/var/lib/haproxy/server-state') do
  it { should exist }
end

describe file('/etc/haproxy/haproxy.cfg') do
  its('content') { should include 'frontend lb_test_6443' }
end

# gobgpd: only over mTLS on the node address, and only VIP-pool /32s get in.
describe port(50051) do
  it { should be_listening }
  its('addresses') { should eq [address] }
end

describe command("#{gobgp} global") do
  its('exit_status') { should_not eq 0 }
end

describe command("#{gobgp} --tls-client-cert-file /etc/lb-test/client.crt --tls-client-key-file /etc/lb-test/client.key " \
                 'global rib add 10.62.0.9/32 -a ipv4 && ' \
                 "#{gobgp} --tls-client-cert-file /etc/lb-test/client.crt --tls-client-key-file /etc/lb-test/client.key " \
                 'global rib add 192.168.50.0/24 -a ipv4 && ' \
                 "#{gobgp} --tls-client-cert-file /etc/lb-test/client.crt --tls-client-key-file /etc/lb-test/client.key " \
                 'global rib -a ipv4') do
  its('stdout') { should include '10.62.0.9/32' }
  its('stdout') { should_not include '192.168.50.0/24' }
end

# BindsTo: stopping HAProxy takes the speaker (and so the routes) down; starting it
# brings the speaker back.
describe command('systemctl stop haproxy && sleep 1 && systemctl is-active gobgpd; ' \
                 'systemctl start haproxy && sleep 2 && systemctl is-active gobgpd') do
  its('stdout') { should eq "inactive\nactive\n" }
end
