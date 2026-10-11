# A release tarball verified against the project's official checksum list (never a
# hard-coded hash), unpacked into a versioned directory, with one binary linked.
#
# Artifacts go to a stable cache, NOT Chef::Config[:file_cache_path]: under
# homelab-infra's converge play that cache lives inside a staging dir recreated on
# every run, so every apply would re-download (never changed=0), and a why-run on a
# fresh node would read a checksum list it never fetched (ENOENT). Once the
# versioned binary exists nothing is downloaded at all.
unified_mode true

property :link_to, String, name_property: true # e.g. /usr/local/bin/lego
property :url_base, String, required: true
property :tarball, String, required: true      # file name in the release
property :checksums, String, required: true    # official checksum list in the release
property :install_dir, String, required: true  # versioned, e.g. /opt/lego-5.3.1
property :binary, String, required: true       # path of the binary inside install_dir

CACHE = '/var/cache/homelab-cinc'.freeze

action :install do
  bin = ::File.join(new_resource.install_dir, new_resource.binary)
  sums = ::File.join(CACHE, new_resource.checksums)
  tarball = ::File.join(CACHE, new_resource.tarball)
  installed = -> { ::File.exist?(bin) }

  directory CACHE

  remote_file sums do
    source "#{new_resource.url_base}/#{new_resource.checksums}"
    retries 3
    retry_delay 10
    not_if(&installed)
  end

  remote_file tarball do
    source "#{new_resource.url_base}/#{new_resource.tarball}"
    # nil in why-run on a fresh node: the list above was only "would download".
    checksum(lazy { ::File.exist?(sums) ? ::File.read(sums)[/^(\h{64})\s+#{Regexp.escape(new_resource.tarball)}$/, 1] : nil })
    retries 3
    retry_delay 10
    not_if(&installed)
  end

  archive_file tarball do
    destination new_resource.install_dir
    not_if(&installed)
    # archive_file raises in why-run when the tarball is absent (fresh node: it was
    # only "would download" above). In a real run the download precedes this.
    only_if { ::File.exist?(tarball) }
  end

  link new_resource.link_to do
    to bin
  end
end
