"""Root-helper policy tests with mocked ownership and privileged commands."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RootPolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='wireguard-policy-')
        self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)
        self.conf=self.path/'configs'; self.conf.mkdir(mode=0o700)
        self.safe=self.conf/'safe.conf'; self.safe.write_text('[Interface]\nPrivateKey=PRIVATE_SECRET\nAddress=10.0.0.2/24\n\n[Peer]\nPublicKey=public\nPresharedKey=PSK_SECRET\nEndpoint=192.0.2.1:51820\nAllowedIPs=10.0.0.0/24\n'); self.safe.chmod(0o600)
        source=(ROOT/'omarchy-wireguard-root').read_text()
        self.definitions=source[:source.index('\n[[ ${1:-} == version')]
        self.dispatch=source[source.index('\ncase ${1:-}'):]
        # Only filesystem metadata is mocked. This emulates a root-owned
        # fixture tree without creating real privileged files or processes.
        self.metadata=r'''
stat() {
  local path=${@: -1} mode owner=0
  mode=$(command stat -c %a -- "$path") || return
  [[ $path != /tmp ]] || mode=755
  [[ $path != *userowned* ]] || owner=1000
  printf '%s %s\n' "$owner" "$mode"
}
'''

    def policy(self,config='safe',directory=None):
        script=self.definitions+self.metadata+'\nCONF_DIR=$1\nconfigured "$2"\n'
        return subprocess.run(['bash','-c',script,'test',str(directory or self.conf),config],capture_output=True,timeout=5)

    def test_root_owned_protected_config_is_accepted(self):
        result=self.policy(); self.assertEqual(result.returncode,0,result.stderr); self.assertEqual(result.stdout,b'safe')

    def test_user_owned_config_is_rejected(self):
        p=self.conf/'userowned.conf'; p.write_text(''); p.chmod(0o600)
        self.assertNotEqual(self.policy('userowned').returncode,0)

    def test_writable_file_and_ancestor_are_rejected(self):
        self.safe.chmod(0o666); self.assertNotEqual(self.policy().returncode,0)
        self.safe.chmod(0o600); self.conf.chmod(0o777); self.assertNotEqual(self.policy().returncode,0)

    def test_group_or_world_readable_keys_are_rejected(self):
        for mode in (0o640, 0o644):
            with self.subTest(mode=oct(mode)):
                self.safe.chmod(mode)
                self.assertNotEqual(self.policy().returncode,0)

    def test_untrusted_parent_and_symlinks_are_rejected(self):
        p=self.path/'userowned-parent'; p.mkdir(); (p/'safe.conf').write_text('')
        self.assertNotEqual(self.policy(directory=p).returncode,0)
        (self.conf/'linked.conf').symlink_to(self.safe)
        self.assertNotEqual(self.policy('linked').returncode,0)
        link=self.path/'link'; link.symlink_to(self.conf)
        self.assertNotEqual(self.policy(directory=link).returncode,0)

    def test_invalid_names_and_non_regular_files_are_rejected(self):
        for name in ('../safe','-x','a/b','x'*16,'safe;id'):
            self.assertNotEqual(self.policy(name).returncode,0)
        os.mkfifo(self.conf/'pipe.conf')
        self.assertNotEqual(self.policy('pipe').returncode,0)

    def test_controls_and_secret_filtering(self):
        bindir=self.path/'bin'; bindir.mkdir()
        commands={
            'wg-quick':'#!/bin/bash\nprintf "wg-quick %s\\n" "$*" >> "$TEST_LOG"\n',
            'systemctl':'#!/bin/bash\nif [[ $1 == is-enabled ]]; then echo enabled; else printf "systemctl %s\\n" "$*" >> "$TEST_LOG"; fi\n',
            'wg':'#!/bin/bash\nif [[ $2 == interfaces ]]; then echo safe; else case "${3:-}" in listen-port) echo 51820;; dump) printf "PRIVATE_SECRET\\tpublic\\t51820\\toff\\npublic\\tPSK_SECRET\\t192.0.2.1:51820\\t10.0.0.0/24\\t1000\\t10\\t20\\t25\\n";; esac; fi\n'
        }
        for name,contents in commands.items():
            p=bindir/name; p.write_text(contents); p.chmod(0o700)
        env=dict(os.environ,TEST_LOG=str(self.path/'calls'))
        prefix=self.definitions+self.metadata+'\nCONF_DIR=$1\nPATH="$2:/usr/bin:/bin"\nshift 2\n'
        for action in ('up','down','enable','disable'):
            result=subprocess.run(['bash','-c',prefix+self.dispatch,'test',str(self.conf),str(bindir),action,'safe'],env=env,capture_output=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len((self.path/'calls').read_text().splitlines()),4)
        result=subprocess.run(['bash','-c',prefix+self.dispatch,'test',str(self.conf),str(bindir),'status'],env=env,capture_output=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn(b'PRIVATE_SECRET',result.stdout); self.assertNotIn(b'PSK_SECRET',result.stdout)
        self.assertEqual(json.loads(result.stdout)['configs']['safe']['autostart'],True)
        self.assertEqual(json.loads(result.stdout)['live']['safe']['peers'][0]['publicKey'],'public')


if __name__ == "__main__": unittest.main()
