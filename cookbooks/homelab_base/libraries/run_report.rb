# Each cinc-client run writes its outcome to node_exporter's textfile collector.
# Without a Chef server this is the only record of a run, and it is what turns
# "a why-run would change something" (drift) into an alert through the existing
# VictoriaMetrics/Alertmanager.
module HomelabBase
  module RunReport
    def self.write(dir, mode, success, updated)
      # First why-run on a fresh node: node_exporter (and its dir) is not there yet.
      return unless ::File.directory?(dir)

      path = ::File.join(dir, "cinc_#{mode.tr('-', '_')}.prom")
      ::File.write("#{path}.tmp", <<~PROM)
        # HELP homelab_cinc_last_run_timestamp_seconds When the last cinc-client run ended.
        # TYPE homelab_cinc_last_run_timestamp_seconds gauge
        homelab_cinc_last_run_timestamp_seconds{mode="#{mode}"} #{Time.now.to_i}
        # HELP homelab_cinc_last_run_success 1 if the last run finished without error.
        # TYPE homelab_cinc_last_run_success gauge
        homelab_cinc_last_run_success{mode="#{mode}"} #{success ? 1 : 0}
        # HELP homelab_cinc_resources_updated Resources the last run updated; for why-run, would update.
        # TYPE homelab_cinc_resources_updated gauge
        homelab_cinc_resources_updated{mode="#{mode}"} #{updated}
      PROM
      # Atomic: the collector must never read a half-written file.
      ::File.rename("#{path}.tmp", path)
    end
  end
end
