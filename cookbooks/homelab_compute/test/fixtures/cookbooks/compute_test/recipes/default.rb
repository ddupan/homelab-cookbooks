# Kitchen stand-in for an Ayatori release: the same tarball and checksum list names,
# served from file://, so the cookbook's verified download runs as on a real host. The
# binary proves what the real agent needs from its unit — its config and the system
# libvirt — and then idles. The real agent is tested against libvirt in Ayatori.
directory '/etc/compute-test/agent/pkg' do
  recursive true
end

file '/etc/compute-test/agent/pkg/compute-agent' do
  content <<~SH
    #!/bin/sh
    set -e
    [ "$1" = -config ] && [ -r "$2" ]
    virsh -c qemu:///system uri
    touch /var/lib/ayatori/compute-agent/started
    exec sleep infinity
  SH
  mode '0755'
end

# imds would replace nftables rules; the stand-in only proves its unit starts it with
# the agent's state directory.
file '/etc/compute-test/agent/pkg/imds' do
  content <<~SH
    #!/bin/sh
    set -e
    [ "$1" = -state-dir ] && [ "$2" = /var/lib/ayatori/compute-agent ]
    exec sleep infinity
  SH
  mode '0755'
end

execute 'test agent release' do
  cwd '/etc/compute-test/agent'
  command <<~SH
    set -e
    tar -C pkg -czf ayatori-compute-agent_0.0.0-test_linux_amd64.tar.gz compute-agent
    tar -C pkg -czf ayatori-imds_0.0.0-test_linux_amd64.tar.gz imds
    sha256sum ayatori-*_0.0.0-test_linux_amd64.tar.gz > ayatori_0.0.0-test_checksums.txt
  SH
  creates '/etc/compute-test/agent/ayatori_0.0.0-test_checksums.txt'
end

# The deployer's join, minus the token: only its presence matters to the unit.
directory '/etc/ayatori/compute-agent' do
  recursive true
  mode '0700'
end

file '/etc/ayatori/compute-agent/bootstrap-kubeconfig' do
  content "apiVersion: v1\nkind: Config\n"
  mode '0400'
end
