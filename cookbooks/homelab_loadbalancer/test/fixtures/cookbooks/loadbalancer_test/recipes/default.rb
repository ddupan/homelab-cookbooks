# Kitchen stand-in for the ACME client and for Bao: a server certificate for the node
# address at the path lego's deploy hook writes (so the cookbook skips issuing it) and a client CA plus one client certificate, which the InSpec suite uses to
# call the APIs the way Ayatori does. Test material only.
package 'openssl'

# The LB hosts' LXC template has no gnupg, dokken's image does; without this, Kitchen
# passes recipes that call gpg and real hosts fail on them.
package %w(gnupg gpg-agent dirmngr gpg) do
  action :purge
end

# Nor sudo, which dataplaneapi's systemd reload strategy silently requires. The package
# refuses removal without a root password, so remove only the binary.
file '/usr/bin/sudo' do
  action :delete
end

directory '/etc/lb-test'

execute 'test certificates' do
  cwd '/etc/lb-test'
  command <<~SH
    set -e
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=server-ca \
      -keyout server-ca.key -out server-ca.pem
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=lb -keyout server.key -out server.csr
    printf 'subjectAltName=IP:#{node['ipaddress']}\\nextendedKeyUsage=serverAuth\\n' > server.ext
    openssl x509 -req -in server.csr -CA server-ca.pem -CAkey server-ca.key -CAcreateserial -days 30 \
      -extfile server.ext -out server.crt
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=client-ca \
      -keyout client-ca.key -out client-ca.pem
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=ayatori-dev-controller \
      -keyout client.key -out client.csr
    printf 'extendedKeyUsage=clientAuth\\n' > client.ext
    openssl x509 -req -in client.csr -CA client-ca.pem -CAkey client-ca.key -CAcreateserial -days 30 \
      -extfile client.ext -out client.crt
    # A client certificate from a different CA, e.g. another environment's controller.
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=other \
      -keyout other.key -out other.crt
    install -d /etc/ayatori-lb/tls
    install -m 0644 server.crt /etc/ayatori-lb/tls/server.crt
    install -m 0600 server.key /etc/ayatori-lb/tls/server.key
  SH
  creates '/etc/lb-test/other.crt'
end

# Kitchen stand-in for an Ayatori release: the same tarball and checksum list names,
# served from file://, so the cookbook's verified download runs as on a real host. The
# binary proves what the real agent needs from its unit — the config, CAP_NET_ADMIN on
# lo, show stat on its HAProxy socket — and then idles.
directory '/etc/lb-test/agent/pkg' do
  recursive true
end

file '/etc/lb-test/agent/pkg/lb-agent' do
  content <<~SH
    #!/bin/sh
    set -e
    [ "$1" = -config ] && [ -r "$2" ]
    ip addr add 10.62.0.250/32 dev lo
    ip addr del 10.62.0.250/32 dev lo
    echo 'show stat' | socat - UNIX-CONNECT:"$(sed -n 's/.*"haproxySocket": "\\(.*\\)".*/\\1/p' "$2")" | grep -q '^# pxname'
    exec sleep infinity
  SH
  mode '0755'
end

execute 'test agent release' do
  cwd '/etc/lb-test/agent'
  command <<~SH
    set -e
    tar -C pkg -czf ayatori-lb-agent_0.0.0-test_linux_amd64.tar.gz lb-agent
    sha256sum ayatori-lb-agent_0.0.0-test_linux_amd64.tar.gz > ayatori_0.0.0-test_checksums.txt
  SH
  creates '/etc/lb-test/agent/ayatori_0.0.0-test_checksums.txt'
end
