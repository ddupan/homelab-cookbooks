# Ayatori compute node (ADR-0015). Chef owns the node — libvirt/QEMU packages, the
# agent binary, its config and unit; Ayatori owns what libvirt runs (the agent
# converges it from the API), and the deployer joins the node (ADR-0021/0022).
compute = node['homelab_compute']
raise 'homelab_compute.agent.version must be set by the node policy' if compute['agent']['version'].nil?

# ovmf 提供 UEFI 固件；swtpm 与 swtpm-tools 提供 vTPM 模拟器及其状态初始化。
package %w(libvirt-daemon-system qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools) do
  options '--no-install-recommends'
end

# Debian 13 runs the monolithic libvirtd, socket-activated. Started here rather than
# trusting the package: nothing else brings it up where package scripts start no services.
service 'libvirtd' do
  action [:enable, :start]
end

homelab_compute_agent 'default' do
  version compute['agent']['version']
  url_base compute['agent']['url_base'] if compute['agent']['url_base']
  node_name node['hostname']
  host_reserved_memory compute['host_reserved_memory']
  node_labels compute['node_labels'].to_h
  metrics_address "#{node['ipaddress']}:9642"
end
