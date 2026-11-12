# Kitchen stand-ins for what the real hosts get from elsewhere. Test material only.

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
