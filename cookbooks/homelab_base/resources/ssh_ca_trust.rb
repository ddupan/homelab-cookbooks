# Make sshd accept the short-lived user certificates OpenBao signs. Additive:
# ordinary key auth keeps working.
unified_mode true

property :source, String, name_property: true
property :key_path, String, default: '/etc/ssh/openbao_user_ca.pub'
# Listen only on this address instead of all of them (homelab_base.listen_address).
# Lives here because this resource owns the ssh service and its safe restart.
property :listen, String

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

  if new_resource.listen
    file '/etc/ssh/sshd_config.d/40-listen.conf' do
      content "# Managed by Cinc (homelab_base)\nListenAddress #{new_resource.listen}\n"
      mode '0644'
      notifies :reload, 'service[ssh]'
    end

    # Under socket activation sshd uses the socket systemd hands it and ignores
    # ListenAddress, so ssh.socket must listen on the address too. FreeBind: the
    # socket comes up before the network has assigned the address at boot.
    directory '/etc/systemd/system/ssh.socket.d'

    file '/etc/systemd/system/ssh.socket.d/listen.conf' do
      content <<~UNIT
        # Managed by Cinc (homelab_base)
        [Socket]
        ListenStream=
        ListenStream=#{new_resource.listen}:22
        FreeBind=yes
      UNIT
      mode '0644'
      notifies :run, 'execute[rebind ssh.socket]'
    end

    # The running sshd holds the old listening fd and systemd refuses to restart the
    # socket while its service is active, so stop sshd first (KillMode=process: open
    # sessions survive). ssh.service is started whatever the socket does: without a
    # socket it binds ListenAddress itself, so a failed rebind never locks us out.
    execute 'rebind ssh.socket' do
      command 'systemctl daemon-reload && if systemctl -q is-enabled ssh.socket; then ' \
              'systemctl stop ssh.service; systemctl restart ssh.socket; rc=$?; ' \
              'systemctl start ssh.service && exit $rc; fi'
      action :nothing
    end
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
