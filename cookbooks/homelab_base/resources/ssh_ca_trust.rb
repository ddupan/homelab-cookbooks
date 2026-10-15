# Make sshd accept the short-lived user certificates OpenBao signs. Additive:
# ordinary key auth keeps working.
unified_mode true

property :source, String, name_property: true
property :key_path, String, default: '/etc/ssh/openbao_user_ca.pub'

action :install do
  # Owns its precondition rather than assuming every image ships sshd (dokken's do not).
  package 'openssh-server'

  remote_file new_resource.key_path do
    source new_resource.source
    mode '0644'
    retries 3
    retry_delay 10
    verify { |path| ::File.read(path).match?(/\Assh-(rsa|ed25519|ecdsa)/) }
    notifies :reload, 'service[ssh]'
  end

  # Drop-in only: every supported release (Debian 12+, Ubuntu 22.04+) Includes
  # sshd_config.d, so there is no fallback edit of the main sshd_config.
  file '/etc/ssh/sshd_config.d/50-openbao-ca.conf' do
    content "# Managed by Cinc (homelab_base)\nTrustedUserCAKeys #{new_resource.key_path}\n"
    mode '0644'
    notifies :reload, 'service[ssh]'
  end

  service 'ssh' do
    # Validate first: a broken config must never reach a running sshd (lock-out).
    # sshd -t needs /run/sshd, which only exists while ssh.service runs.
    # Restart, not SIGHUP: under socket activation (Debian 13 LXC templates, Ubuntu
    # 24.04) sshd re-execs on SIGHUP, tries to bind :22 that ssh.socket holds and
    # dies ("Cannot bind any address"). A restart hands it the socket again; open
    # sessions are separate processes and survive. try-: if sshd is not running,
    # the next connection starts it with the new config anyway.
    reload_command 'install -d -m 0755 /run/sshd && /usr/sbin/sshd -t && systemctl try-restart ssh'
    action :nothing
  end
end
