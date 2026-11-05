# Kitchen has no Bao or SPIRE: self-signed stand-ins, so homelab_data::etcd skips its
# first issuance exactly as on an adopted member that already has certificates.
directory '/etc/homelab-etcd'

%w(server peer gateway admin).each do |c|
  execute "stand-in #{c} certificate" do
    command "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=#{c} " \
            "-keyout /etc/homelab-etcd/#{c}.key -out /etc/homelab-etcd/#{c}.crt"
    creates "/etc/homelab-etcd/#{c}.crt"
  end
end
