# HAProxy for an Ayatori LoadBalancer host. Two config files, two owners:
#   base.cfg     — Chef: global, defaults, resolvers. Never touched by the API.
#   haproxy.cfg  — dataplaneapi: every lb_* frontend/backend Ayatori writes.
# Chef must never render haproxy.cfg: dataplaneapi rewrites it on every change, so a
# template would fight the API on each converge. It is only created when missing.
unified_mode true

property :version, String, default: '3.4'
# LAN resolver for DNS endpoints; Ayatori refers to it as --loadbalancer-resolvers=lan.
property :resolver, String, required: true
# Bounds how long the old worker keeps serving connections after a reload, and with
# it how long a drained endpoint can keep connections past its drainTimeout.
property :hard_stop_after, String, default: '30m'

action :install do
  # Debian 13 ships 3.0; the LB contract (Data Plane API v3.4, dynamic servers in
  # maint, frontend/backend name rules) was verified against 3.4.
  # Upstream publishes a binary keyring, so it is fetched as-is and handed to apt via
  # signed-by. apt_repository's own `key` path imports it with gpg and gpg-agent, which
  # minimal images (the LB hosts' LXC template) lack; Kitchen's dokken image has them,
  # so only a real host showed it.
  remote_file '/etc/apt/keyrings/haproxy.gpg' do
    source 'https://haproxy.debian.net/haproxy-archive-keyring.gpg'
    mode '0644'
    retries 3
    retry_delay 10
    # An HTML error page as the keyring would only fail later, at apt update; refuse
    # anything that does not start with an OpenPGP public-key packet.
    verify { |path| [0x99, 0xc6].include?(::File.binread(path, 1).ord) }
  end

  apt_repository 'haproxy' do
    uri 'http://haproxy.debian.net'
    distribution "trixie-backports-#{new_resource.version}"
    components ['main']
    key nil
    signed_by '/etc/apt/keyrings/haproxy.gpg'
  end

  apt_preference 'haproxy' do
    pin "version #{new_resource.version}.*"
    pin_priority '1001'
  end

  # socat: the reload saves server state through the admin socket first.
  apt_package %w(haproxy socat) do
    options '--no-install-recommends'
    retries 3
    retry_delay 5
  end

  # Frontends bind their VIP before gobgpd announces it, i.e. before the address is
  # routed here at all.
  # Not the built-in sysctl resource: it runs `sysctl -p`, which fails on Debian 13
  # because /etc/sysctl.conf no longer exists.
  file '/etc/sysctl.d/90-ayatori-loadbalancer.conf' do
    content "net.ipv4.ip_nonlocal_bind = 1\n"
    mode '0644'
  end

  execute 'sysctl -w net.ipv4.ip_nonlocal_bind=1' do
    not_if { ::File.read('/proc/sys/net/ipv4/ip_nonlocal_bind').strip == '1' }
  end

  file '/etc/haproxy/base.cfg' do
    content <<~CFG
      # Managed by Cinc (homelab_loadbalancer). Ayatori's sections live in haproxy.cfg.
      global
          log /dev/log local0
          user haproxy
          group haproxy
          stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
          # Saved by ExecReload; without it every reload starts each server in its
          # init-state (fully-down) and the whole host drops traffic for rise x inter.
          server-state-file /var/lib/haproxy/server-state
          hard-stop-after #{new_resource.hard_stop_after}

      defaults
          mode tcp
          log global
          load-server-state-from-file global
          # Ayatori sets client/server per LoadBalancer port; these only cover gaps.
          timeout connect 5s
          timeout client 1m
          timeout server 1m

      resolvers lan
          nameserver lan #{new_resource.resolver}
          hold valid 10s
          accepted_payload_size 8192
    CFG
    mode '0644'
    notifies :reload, 'service[haproxy]'
  end

  file '/etc/haproxy/haproxy.cfg' do
    content "# Managed by dataplaneapi (Ayatori LoadBalancer). Do not edit.\n"
    mode '0644'
    action :create_if_missing
  end

  directory '/etc/systemd/system/haproxy.service.d'

  # The package unit validates and loads only haproxy.cfg; both files are needed, and
  # every reload saves server state first.
  file '/etc/systemd/system/haproxy.service.d/ayatori.conf' do
    content <<~UNIT
      [Service]
      RuntimeDirectory=haproxy
      ExecStartPre=
      ExecStartPre=/usr/sbin/haproxy -c -q -f /etc/haproxy/base.cfg -f /etc/haproxy/haproxy.cfg
      ExecStart=
      ExecStart=/usr/sbin/haproxy -Ws -S /run/haproxy-master.sock -p /run/haproxy.pid -f /etc/haproxy/base.cfg -f /etc/haproxy/haproxy.cfg
      ExecReload=
      ExecReload=/usr/sbin/haproxy -c -q -f /etc/haproxy/base.cfg -f /etc/haproxy/haproxy.cfg
      ExecReload=/bin/sh -c 'echo "show servers state" | socat stdio /run/haproxy/admin.sock > /var/lib/haproxy/server-state.tmp && mv -f /var/lib/haproxy/server-state.tmp /var/lib/haproxy/server-state'
      ExecReload=/bin/kill -USR2 $MAINPID
    UNIT
    mode '0644'
    notifies :run, 'execute[systemctl daemon-reload]', :immediately
    notifies :restart, 'service[haproxy]'
  end

  execute 'systemctl daemon-reload' do
    action :nothing
  end

  service 'haproxy' do
    action [:enable, :start]
  end
end
