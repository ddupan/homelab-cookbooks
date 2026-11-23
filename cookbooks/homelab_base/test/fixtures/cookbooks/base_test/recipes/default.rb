# Plays OpenBao for Kitchen: the two unauthenticated documents homelab_base::default fetches
# (internal CA, SSH user CA public key), served from files so the suite never reaches the real Bao.
# kitchen.yml points homelab_base.bao at file:///var/tmp/fake-bao. Both are throwaway test keys
# whose private halves were discarded; nothing trusts them outside this container.
{ 'v1/pki/ca/pem' => 'ca.pem', 'v1/ssh-client-signer/public_key' => 'ssh_ca.pub' }.each do |path, source|
  target = "/var/tmp/fake-bao/#{path}"
  directory ::File.dirname(target) do
    recursive true
  end
  cookbook_file target do
    source source
    mode '0644'
  end
end
