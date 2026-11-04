"""Installer tests using temporary destinations and mocked privileges."""
import hashlib
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


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='wireguard-installer-test-')
        self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)
        self.bindir=self.path/'bin'; self.bindir.mkdir()
        self.destdir=self.path/'local/libexec/omarchy-wireguard'
        self.rules=self.path/'sudoers.d'
        self.helper=(ROOT/'omarchy-wireguard-root').read_bytes()
        source=(ROOT/'install-helper').read_text()
        begin=source.index("root_install='")
        end=source.index("\n'\n",begin)+3
        self.payload=subprocess.check_output(['bash','-c',source[begin:end]+'\nprintf %s "$root_install"'],text=True)
        self.payload=self.payload.replace('/usr/local/libexec/omarchy-wireguard',str(self.destdir)).replace('/etc/sudoers.d',str(self.rules))
        self.payload=self.payload.replace('export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
                                          'export PATH='+str(self.bindir)+':/usr/bin:/bin')
        # Emulate privileged ownership while using real modes/symlinks.
        self.metadata=r'''
stat() {
  local path=${@: -1} mode
  mode=$(command stat -c %a -- "$path") || return
  [[ $path != /tmp ]] || mode=755
  printf '0 %s\n' "$mode"
}
'''
        executable(self.bindir/'chown','#!/bin/bash\nexit 0\n')
        executable(self.bindir/'mv',r'''#!/bin/bash
source_path=${@: -2:1}
if [[ ${FAIL_RULE_MOVE:-0} == 1 && ${source_path##*/} == rule && ! -e $FAIL_MARKER ]]; then
  touch "$FAIL_MARKER"
  exit 1
fi
exec /usr/bin/mv "$@"
''')

    def run_installer(self,checksum=None,fail=False):
        env=dict(os.environ,FAIL_RULE_MOVE='1' if fail else '0',FAIL_MARKER=str(self.path/'failed-once'))
        checksum=checksum or hashlib.sha256(self.helper).hexdigest()
        return subprocess.run(['bash','-c',self.metadata+self.payload,'test','root',checksum],
                              input=self.helper,capture_output=True,env=env,timeout=10)

    def test_staged_installer_and_sudoers_fragment(self):
        result=self.run_installer()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.destdir/'omarchy-wireguard-root').read_bytes(),self.helper)
        self.assertEqual((self.rules/'omarchy-wireguard').stat().st_mode & 0o777,0o440)
        rule=(self.rules/'omarchy-wireguard').read_text()
        self.assertIn('Defaults!OMARCHY_WIREGUARD_READ !log_allowed',rule)
        self.assertNotIn('Defaults!'+str(self.destdir/'omarchy-wireguard-root')+' !log_allowed',rule)
        self.assertIn('NOPASSWD:',rule)

    def test_changed_snapshot_is_rejected(self):
        result=self.run_installer(checksum='0'*64)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.destdir/'omarchy-wireguard-root').exists())
        self.assertFalse((self.rules/'omarchy-wireguard').exists())

    def test_symlink_ancestor_is_rejected(self):
        victim=self.path/'victim'; victim.mkdir()
        (self.path/'local').symlink_to(victim)
        result=self.run_installer()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(list(victim.iterdir()),[])

    def test_partial_replacement_restores_previous_files(self):
        self.destdir.mkdir(parents=True); self.rules.mkdir()
        old_helper=self.destdir/'omarchy-wireguard-root'; old_helper.write_text('old helper\n'); old_helper.chmod(0o755)
        old_rule=self.rules/'omarchy-wireguard'; old_rule.write_text('# previous rule\n'); old_rule.chmod(0o440)
        result=self.run_installer(fail=True)
        self.assertNotEqual(result.returncode,0)
        self.assertTrue((self.path/'failed-once').exists())
        self.assertEqual(old_helper.read_text(),'old helper\n')
        self.assertEqual(old_rule.read_text(),'# previous rule\n')


if __name__ == "__main__": unittest.main()
