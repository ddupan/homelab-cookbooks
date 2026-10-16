# Trust an internal CA system-wide (Debian family: update-ca-certificates).
unified_mode true

property :ca_name, String, name_property: true
property :source, String, required: true

action :install do
  # Declared, not assumed: update-ca-certificates and the directory below come from it.
  apt_package 'ca-certificates'

  remote_file "/usr/local/share/ca-certificates/#{new_resource.ca_name}.crt" do
    source new_resource.source
    mode '0644'
    retries 3
    retry_delay 10
    # An HTML error page installed as a trust anchor would quietly break every TLS
    # client on the host, so anything that is not a PEM certificate is refused.
    verify { |path| ::File.read(path).include?('-----BEGIN CERTIFICATE-----') }
    notifies :run, 'execute[update-ca-certificates]', :immediately
  end

  execute 'update-ca-certificates' do
    action :nothing
  end
end
