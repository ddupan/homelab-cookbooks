# Server-side applies a manifest file with k0s's admin credentials, only when
# `kubectl diff` reports a difference. While a dependency (a namespace, a CRD) does not
# exist yet the diff fails too, so apply runs and reports the real error.
unified_mode true

property :path, String, name_property: true

action :apply do
  kubectl = '/usr/local/bin/k0s kubectl'
  execute "apply #{::File.basename(new_resource.path)}" do
    command "#{kubectl} apply --server-side --force-conflicts -f #{new_resource.path}"
    not_if "#{kubectl} diff --server-side --force-conflicts -f #{new_resource.path}"
  end
end
