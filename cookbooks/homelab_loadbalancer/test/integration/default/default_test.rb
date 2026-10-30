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

describe file('/usr/local/sbin/ayatori-lb-cert') do
  its('content') { should include 'https://bao.invalid:8200/v1/pki/acme/directory' }
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

# The host can restart: dataplaneapi rewrites its own yml and ExecStartPre copies
# Chef's source over it on every start, so what Ayatori wrote must survive that.
describe command(<<~SH) do
  systemctl restart dataplaneapi
  for i in $(seq 30); do
    curl -sf -o /dev/null #{tls} -u ayatori:test-only #{api}/configuration/version && break
    sleep 1
  done
  curl -s -o /dev/null -w '%{http_code}' #{tls} -u ayatori:test-only #{api}/configuration/frontends/lb_test_6443
SH
  its('stdout') { should eq '200' }
end

# Chef never owns haproxy.cfg: a converge after Ayatori wrote to it updates nothing
# and keeps the lb_* sections. Kitchen's own converges both ran before Ayatori did,
# so only this one shows it. Paths are dokken's; client_no_updated_resources.rb fails
# the run if any resource updates.
describe command('/opt/cinc/bin/cinc-client -z -l warn -c /opt/kitchen/client.rb ' \
                 '--config /opt/kitchen/client_no_updated_resources.rb -j /opt/kitchen/dna.json ' \
                 '--chef-zero-port 8889') do
  its('exit_status') { should eq 0 }
end

describe file('/etc/haproxy/haproxy.cfg') do
  its('content') { should include 'frontend lb_test_6443' }
end

describe port(5555) do
  it { should be_listening }
  its('addresses') { should eq [address] }
end

# Nothing secret on the node: the Basic password exists only as a SHA-512 crypt hash,
# and only root can read it. dataplaneapi rewrites its working copy 0644 whatever
# ExecStartPre installed, so the 0700 directory is what keeps that copy private.
%w(/etc/dataplaneapi/dataplaneapi.yml /var/lib/dataplaneapi/dataplaneapi.yml).each do |path|
  describe file(path) do
    its('owner') { should eq 'root' }
    its('content') { should match(/password: ['"]?\$6\$/) }
    its('content') { should_not include 'test-only' }
  end
end

describe file('/etc/dataplaneapi/dataplaneapi.yml') do
  its('mode') { should cmp '0600' }
end

describe directory('/var/lib/dataplaneapi') do
  its('mode') { should cmp '0700' }
  its('owner') { should eq 'root' }
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

# Anything still on the wildcard is unreachable through a VIP but not through the
# host address. 10.62.0.9 is local here the way the agent makes a VIP local.
describe command(<<~SH) do
  set -e
  host=$(hostname -I | awk '{print $1}')
  ip addr add 10.62.0.9/32 dev lo
  socat TCP-LISTEN:7777,reuseaddr,fork SYSTEM:'echo up' & pid=$!
  sleep 1
  vip=$(socat -T2 - TCP:10.62.0.9:7777 2>&1 </dev/null || true)
  direct=$(socat -T2 - TCP:$host:7777 </dev/null)
  kill $pid; ip addr del 10.62.0.9/32 dev lo
  echo "vip=$vip"; echo "direct=$direct"
SH
  its('stdout') { should match(/^vip=.*Connection refused/) }
  its('stdout') { should include 'direct=up' }
end

describe service('ayatori-vip-guard') do
  it { should be_enabled }
end
