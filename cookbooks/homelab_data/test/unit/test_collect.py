import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('collector', Path(__file__).parents[2] / 'files/default/collect.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CollectorTests(unittest.TestCase):
    def test_full_backup_ignores_failed_and_incremental(self):
        data = [{'name': 'prod', 'status': {'code': 0}, 'backup': [
            {'type': 'full', 'error': False, 'timestamp': {'stop': 100}},
            {'type': 'full', 'error': True, 'timestamp': {'stop': 200}},
            {'type': 'incr', 'error': False, 'timestamp': {'stop': 300}},
        ]}]
        self.assertEqual(collector.latest_backup(data), 100)
        data[0]['backup'] = []
        self.assertEqual(collector.latest_backup(data), 0)
        data[0]['status']['code'] = 2
        with self.assertRaises(ValueError):
            collector.latest_backup(data)

    def test_partial_snapshot_not_counted(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, '20260927T040000Z.db.partial').touch()
            self.assertEqual(collector.latest_snapshot(d), 0)
            p = Path(d, '20260926T040000Z.db')
            p.touch()
            self.assertEqual(collector.latest_snapshot(d), p.stat().st_mtime)

    def test_missing_certificate_does_not_hide_other_failures(self):
        with tempfile.TemporaryDirectory() as d:
            config = {'certificates': [{'name': 'missing', 'path': d + '/none'}],
                      'snapshot_dir': d, 'dev': True, 'repository': True}
            with patch.object(collector, 'command', side_effect=subprocess.TimeoutExpired('probe', 15)):
                output = collector.collect(config)
            self.assertIn('certificate="missing"} 0.0', output)
            self.assertIn('homelab_data_dev_sql_ready 0.0', output)
            self.assertIn('backup="postgresql-prod"} 0.0', output)
            self.assertIn('homelab_data_collection_timestamp_seconds', output)

    def test_read_only_dev_fails_readiness(self):
        with tempfile.TemporaryDirectory() as d:
            with patch.object(collector, 'command', return_value='0'):
                output = collector.collect({'certificates': [], 'snapshot_dir': d, 'dev': True})
            self.assertIn('homelab_data_dev_sql_ready 0.0', output)
            self.assertIn('check="dev_sql_ready"} 1.0', output)

    def test_atomic_output_replaces_old_success(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, 'health.prom')
            collector.publish(p, 'success 1\n')
            collector.publish(p, 'success 0\n')
            self.assertEqual(p.read_text(), 'success 0\n')
            self.assertEqual(p.stat().st_mode & 0o777, 0o644)
            self.assertEqual(list(Path(d).iterdir()), [p])

    def test_actual_certificate_chain_earliest_expiry(self):
        with tempfile.TemporaryDirectory() as d:
            for days in (2, 30):
                subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
                                '-nodes', '-subj', '/CN=test', '-days', str(days),
                                '-keyout', d + '/key', '-out', d + '/' + str(days)],
                               check=True, capture_output=True)
            p = Path(d, 'chain')
            p.write_text(Path(d, '30').read_text() + Path(d, '2').read_text())
            self.assertEqual(collector.certificate_expiry(p), collector.certificate_expiry(Path(d, '2')))


    def test_restart_pending_compares_file_change_with_process_start(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d, 'etcd.yml')
            path.touch()
            os.utime(path, (2000, 2000), follow_symlinks=False)
            show = 'ActiveState=active\nExecMainStartTimestamp=Thu 1970-01-01 00:16:40 UTC'
            config = {'certificates': [], 'snapshot_dir': d,
                      'restart_units': [{'unit': 'homelab-etcd', 'paths': [str(path)]}]}
            with patch.object(collector, 'command', side_effect=lambda argv: show if argv[0] == 'systemctl' else '1000'):
                self.assertIn('homelab_data_restart_pending{unit="homelab-etcd"} 1.0', collector.collect(config))
            with patch.object(collector, 'command', side_effect=lambda argv: show if argv[0] == 'systemctl' else '3000'):
                self.assertIn('homelab_data_restart_pending{unit="homelab-etcd"} 0.0', collector.collect(config))
            stopped = 'ActiveState=inactive\nExecMainStartTimestamp='
            with patch.object(collector, 'command', return_value=stopped):
                self.assertIn('check_success{check="restart_pending",unit="homelab-etcd"} 0.0', collector.collect(config))


if __name__ == '__main__':
    unittest.main()
