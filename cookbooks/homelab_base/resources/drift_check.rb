# Hourly why-run against the policy the last manual converge applied. It changes
# nothing; the run report (libraries/run_report.rb) records how many resources
# WOULD change, which is the drift signal. Applying stays a manual decision.
unified_mode true

property :policy_dir, String, name_property: true
property :on_calendar, String, default: 'hourly'

action :install do
  systemd_unit 'homelab-cinc-drift.service' do
    content <<~UNIT
      [Unit]
      Description=Cinc why-run against the last applied policy (drift check; changes nothing)
      # Nothing applied yet (or bootstrapped by hand): nothing to compare against.
      ConditionPathExists=#{new_resource.policy_dir}/Policyfile.lock.json

      [Service]
      Type=oneshot
      WorkingDirectory=#{new_resource.policy_dir}
      ExecStart=/opt/cinc/bin/cinc-client -z --why-run --no-color
      TimeoutStartSec=30min
    UNIT
    action :create
  end

  systemd_unit 'homelab-cinc-drift.timer' do
    content <<~UNIT
      [Unit]
      Description=Hourly Cinc drift check

      [Timer]
      OnCalendar=#{new_resource.on_calendar}
      RandomizedDelaySec=15min
      Persistent=true

      [Install]
      WantedBy=timers.target
    UNIT
    action [:create, :enable, :start]
  end
end
