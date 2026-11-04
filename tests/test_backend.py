"""Backend controls and inventory tests with mocked commands."""
import shutil
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def executable(path,text):
    path.write_text(text)
    path.chmod(0o700)


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='wireguard-backend-test-')
        self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)
        self.bin=self.path/'bin'; self.bin.mkdir()
        for filename in ('omarchy-wireguard-root','runtime.py'):
            shutil.copyfile(ROOT/filename,self.path/filename)
        # The sandbox exposes root-owned /tmp as uid 65534. Only the fixture
        # runtime emulates host ownership; installed source stays unchanged.
        fixture_runtime=self.path/'runtime.py'
        fixture_runtime.write_text(fixture_runtime.read_text().replace(
            'sticky_root = info.st_uid == 0 and',
            'sticky_root = info.st_uid == '+str(Path('/tmp').stat().st_uid)+' and'))
        helper=self.path/'omarchy-wireguard-root'; helper.chmod(0o700)
        code=(ROOT/'omarchy-wireguard').read_text().replace(
            'ROOT_HELPER=/usr/local/libexec/omarchy-wireguard/omarchy-wireguard-root',
            'ROOT_HELPER='+str(helper))
        self.backend=self.path/'omarchy-wireguard'; self.backend.write_text(code)
        self.links=self.path/'links.json'; self.links.write_text('[]')
        self.log=self.path/'calls'
        runtime_directory=self.path/'runtime'; runtime_directory.mkdir(mode=0o700)
        self.env=dict(os.environ,PATH=str(self.bin)+':/usr/bin:/bin',XDG_RUNTIME_DIR=str(runtime_directory),
                      TEST_LINKS=str(self.links),TEST_LOG=str(self.log),TEST_VERSION='3')
        executable(self.bin/'sudo',r'''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
action=sys.argv[3]
with open(os.environ['TEST_LOG'],'a') as output: output.write(action+'\n')
links=Path(os.environ['TEST_LINKS'])
if action=='version': print(os.environ.get('TEST_VERSION','3'))
elif action=='status': print(json.dumps({'version':3,'configs':{},'live':{}}))
elif action=='up': links.write_text('[{"ifname":"lo","ifindex":1,"flags":["UP"],"mtu":65536}]'); print('up')
elif action=='down': links.write_text('[]'); print('down')
elif action in ('enable','disable'): print(action)
else: sys.exit(99)
''')
        executable(self.bin/'ip',r'''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
if os.environ.get('FAIL_INVENTORY'): sys.exit(1)
links=json.loads(Path(os.environ['TEST_LINKS']).read_text())
args=sys.argv[1:]
if args==['-j','link','show','type','wireguard']: print(json.dumps(links))
elif args[:4]==['-j','link','show','dev']: print(json.dumps([x for x in links if x['ifname']==args[4]]))
elif args[:4]==['-j','addr','show','dev']: print('[{"addr_info":[{"local":"127.0.0.1","prefixlen":8}]}]')
else: sys.exit(99)
''')
        executable(self.bin/'resolvectl','#!/bin/bash\nexit 1\n')

    def run_backend(self,*args):
        return subprocess.run(['bash',str(self.backend),*args],env=self.env,capture_output=True,timeout=10)

    def test_all_control_routes_are_preserved(self):
        for action in ('up','down','up','restart','enable','disable'):
            result=self.run_backend(action,'lo')
            self.assertEqual(result.returncode,0,result.stderr+result.stdout)
            self.assertIs(json.loads(result.stdout)['ok'],True)
        calls=self.log.read_text().splitlines()
        self.assertEqual(calls.count('up'),3)
        self.assertEqual(calls.count('down'),2)
        self.assertIn('enable',calls); self.assertIn('disable',calls)

    def test_empty_inventory_and_down_flags(self):
        result=self.run_backend('json')
        self.assertEqual(result.returncode,0,result.stderr+result.stdout)
        self.assertEqual(json.loads(result.stdout)['tunnels'],[])
        self.links.write_text('[{"ifname":"lo","ifindex":1,"flags":[],"mtu":65536}]')
        result=self.run_backend('json')
        self.assertEqual(result.returncode,0,result.stderr+result.stdout)
        tunnel=json.loads(result.stdout)['tunnels'][0]
        self.assertIs(tunnel['up'],False)
        self.assertEqual(tunnel['dns'],[])

    def test_inventory_failure_does_not_become_disconnected(self):
        self.env['FAIL_INVENTORY']='1'
        result=self.run_backend('json')
        self.assertNotEqual(result.returncode,0)
        self.assertIs(json.loads(result.stdout)['ok'],False)

    def test_legacy_helper_cannot_drive_tunnels(self):
        self.env['TEST_VERSION']='2'
        result=self.run_backend('up','lo')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('out of date',json.loads(result.stdout)['error'])
        self.assertEqual(self.log.read_text().splitlines(),['version'])

    def test_unsafe_state_blocks_control(self):
        state=Path(self.env['XDG_RUNTIME_DIR'])/'omarchy-wireguard'; state.mkdir(mode=0o700)
        victim=self.path/'victim'; victim.write_text('keep')
        (state/'lo.driven').symlink_to(victim)
        result=self.run_backend('up','lo')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('up',self.log.read_text().splitlines())
        self.assertEqual(victim.read_text(),'keep')

    def test_demo_mode_is_preserved_and_labeled(self):
        state=Path(self.env['XDG_RUNTIME_DIR'])/'omarchy-wireguard'; state.mkdir(mode=0o700)
        (state/'demo').touch(mode=0o600)
        result=self.run_backend('json')
        self.assertEqual(result.returncode,0,result.stderr+result.stdout)
        self.assertIs(json.loads(result.stdout)['demo'],True)
        result=self.run_backend('up','office')
        self.assertNotEqual(result.returncode,0)


if __name__ == "__main__": unittest.main()
