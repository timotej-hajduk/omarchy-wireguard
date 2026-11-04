"""Private-state and probe tests without network packets or privileges."""
import importlib.util
import sys
from unittest.mock import patch
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


spec = importlib.util.spec_from_file_location('runtime', ROOT / 'runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class StateAndProbeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wireguard-security-')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.environment = patch.dict(os.environ, {'XDG_RUNTIME_DIR': str(self.path)})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        # This sandbox maps root-owned /tmp to uid 65534. Emulate its host
        # ownership, without weakening the production ownership policy.
        original_fstat = os.fstat
        temporary_info = Path('/tmp').stat()
        def host_fstat(fd):
            info = original_fstat(fd)
            if (info.st_dev, info.st_ino) == (temporary_info.st_dev, temporary_info.st_ino):
                values = list(info); values[4] = 0
                return os.stat_result(values)
            return info
        metadata = patch.object(runtime.os, 'fstat', host_fstat)
        metadata.start()
        self.addCleanup(metadata.stop)

    def test_private_state_and_symlink_rejection(self):
        with runtime.contextlib.closing(runtime.PrivateState()) as store:
            store.stamp('wg0.driven')
            self.assertEqual((self.path/'omarchy-wireguard').stat().st_mode & 0o777,0o700)
            self.assertEqual((self.path/'omarchy-wireguard/wg0.driven').stat().st_mode & 0o777,0o600)
            victim=self.path/'victim'; victim.write_text('keep')
            (self.path/'omarchy-wireguard/wg0.lock').symlink_to(victim)
            with self.assertRaises(ValueError), store.lock('wg0.lock'):
                pass
            self.assertEqual(victim.read_text(),'keep')

    def test_symlink_directory_is_rejected(self):
        victim=self.path/'victim'; victim.mkdir()
        (self.path/'omarchy-wireguard').symlink_to(victim)
        with self.assertRaises(OSError): runtime.PrivateState()

    def test_writable_directory_is_rejected(self):
        directory=self.path/'omarchy-wireguard'; directory.mkdir(mode=0o777); directory.chmod(0o777)
        with self.assertRaises(ValueError): runtime.PrivateState()

    def test_hardlinked_marker_is_rejected(self):
        with runtime.contextlib.closing(runtime.PrivateState()) as store:
            victim=self.path/'victim'; victim.write_text('keep')
            os.link(victim,self.path/'omarchy-wireguard/wg0.driven')
            with self.assertRaises(ValueError): store.stamp('wg0.driven')
            self.assertEqual(victim.read_text(),'keep')

    def test_notify_deduplicates_without_following_symlinks(self):
        with patch.object(sys,'argv',['runtime.py','notify','wg0','down','summary','body']), patch.object(runtime,'run') as send:
            runtime.main(); runtime.main()
            self.assertEqual(send.call_count,1)
            self.assertEqual(send.call_args.args[0],['notify-send','-a','WireGuard','--','summary','body'])

    def test_own_actions_suppress_only_the_matching_notification(self):
        with runtime.contextlib.closing(runtime.PrivateState()) as store:
            store.stamp('wg0.driven')
        with patch.object(runtime,'run') as send:
            with patch.object(sys,'argv',['runtime.py','notify','wg0','down','summary']): runtime.main()
            self.assertEqual(send.call_count,0)
            with patch.object(sys,'argv',['runtime.py','notify','wg1','down','summary']): runtime.main()
            self.assertEqual(send.call_count,1)

    def test_literal_probe_is_interface_bound(self):
        calls=[]
        def run(command,seconds=4):
            calls.append(command)
            if command[0]=='ip': return 0,json.dumps([{'ifname':'wg0','flags':['UP']}])
            return 0,'64 bytes: time=12.5 ms'
        with patch.object(runtime,'run',run): self.assertEqual(runtime.probe('wg0','10.0.0.1')['ms'],12.5)
        self.assertEqual(calls[-1],['ping','-n','-I','wg0','-c','1','-W','1','--','10.0.0.1'])

    def test_hostname_resolution_is_scoped_to_interface(self):
        calls=[]
        def run(command,seconds=4):
            calls.append(command)
            if command[0]=='ip': return 0,'[{"ifname":"wg0","flags":["UP"]}]'
            if command[0]=='resolvectl': return 0,'vpn.example: 10.0.0.1\n'
            return 0,'64 bytes: time=1.2 ms'
        with patch.object(runtime,'run',run): runtime.probe('wg0','vpn.example')
        self.assertIn('--interface=wg0',calls[1]); self.assertIn('--cache=no',calls[1])
        self.assertEqual(calls[-1][-1],'10.0.0.1')

    def test_resolution_failure_never_falls_back(self):
        calls=[]
        def run(command,seconds=4):
            calls.append(command)
            return (0,'[{"ifname":"wg0","flags":["UP"]}]') if command[0]=='ip' else (1,'')
        with patch.object(runtime,'run',run), self.assertRaises(ValueError): runtime.probe('wg0','vpn.example')
        self.assertEqual([c[0] for c in calls],['ip','resolvectl'])

    def test_down_interface_is_not_probed(self):
        with patch.object(runtime,'run',return_value=(0,'[{"ifname":"wg0","flags":[]}]')) as run:
            with self.assertRaises(ValueError): runtime.probe('wg0','10.0.0.1')
            self.assertEqual(run.call_count,1)

    def test_probe_timeout_and_output_limits(self):
        with self.assertRaises(TimeoutError): runtime.run([sys.executable,'-c','import time;time.sleep(30)'],0.1)
        with self.assertRaises(ValueError): runtime.run([sys.executable,'-c','print("x"*300000)'])


if __name__ == "__main__": unittest.main()
