import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ProvisioningTests(unittest.TestCase):
    @unittest.skipUnless(os.name=='nt','actual NTFS and Windows PowerShell prefix copy')
    def test_native_prefix_copy_breaks_provider_hardlinks_and_refuses_aliases(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=pathlib.Path(temporary).resolve(strict=True)
            source=root/'provider';source.mkdir()
            original=source/'native.lib';original.write_bytes(b'!<arch>\nactual temporary static archive\n')
            cache=root/'cache.lib';os.link(original,cache)
            self.assertEqual(original.stat().st_nlink,2)
            destination=root/'independent'
            command=['powershell.exe','-NoProfile','-NonInteractive','-File',str(ROOT/'copy-installed-prefix.ps1'),
                     '-Source',str(source),'-Destination',str(destination)]
            environment={key:value for key,value in os.environ.items() if key.lower()!='psmodulepath'}
            subprocess.run(command,check=True,capture_output=True,timeout=30,env=environment)
            self.assertEqual((destination/'native.lib').read_bytes(),original.read_bytes())
            self.assertEqual((destination/'native.lib').stat().st_nlink,1)
            self.assertEqual(original.stat().st_nlink,2)
            self.assertNotEqual((destination/'native.lib').stat().st_ino,original.stat().st_ino)
            result=subprocess.run(command,capture_output=True,timeout=30,env=environment)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual((destination/'native.lib').read_bytes(),original.read_bytes())
            # Add a provider entry after the initial directory enumeration. The
            # copy must use its exact captured set and reject the changed tree.
            mutation=root/'mutate.ps1'
            mutation.write_text('''param([string]$Source,[string]$Destination,[string]$Helper)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$global:FixtureSource=$Source
$global:FixtureHashCalls=0
function Get-FileHash {
    [CmdletBinding()]param([string]$LiteralPath,[string]$Algorithm)
    $result=Microsoft.PowerShell.Utility\\Get-FileHash @PSBoundParameters
    $global:FixtureHashCalls++
    if ($global:FixtureHashCalls -eq 1) {
        [IO.File]::WriteAllBytes((Join-Path $global:FixtureSource 'injected.lib'),[Text.Encoding]::UTF8.GetBytes('unreviewed new source entry'))
    }
    return $result
}
& $Helper -Source $Source -Destination $Destination
''',encoding='utf-8')
            changed=root/'changed'
            result=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-File',str(mutation),
                '-Source',str(source),'-Destination',str(changed),'-Helper',str(ROOT/'copy-installed-prefix.ps1')],capture_output=True,timeout=30,env=environment)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse((changed/'injected.lib').exists())
            self.assertEqual((changed/'native.lib').read_bytes(),original.read_bytes())
            outside=root/'outside';outside.mkdir()
            subprocess.run(['cmd.exe','/c','mklink','/J',str(source/'alias'),str(outside)],check=True,capture_output=True,timeout=30)
            unknown=root/'refused'
            changed=list(command);changed[-1]=str(unknown)
            result=subprocess.run(changed,capture_output=True,timeout=30,env=environment)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(unknown.exists())

    def test_unix_source_and_windows_baseline_match_review_record(self):
        sources = json.loads((ROOT / 'sources.json').read_text())
        unix = (ROOT / 'build-unix.sh').read_text()
        windows = (ROOT / 'build-windows.ps1').read_text()
        manifest = json.loads((ROOT / 'vcpkg.json').read_text())
        self.assertEqual(re.search(r'^version=(.+)$', unix, re.MULTILINE).group(1), sources['ffmpeg']['version'])
        self.assertEqual(re.search(r'^sha256=(.+)$', unix, re.MULTILINE).group(1), sources['ffmpeg']['sha256'])
        self.assertIn("$revision = '" + sources['vcpkg']['revision'] + "'", windows)
        self.assertEqual(manifest['builtin-baseline'], sources['vcpkg']['revision'])
        ffmpeg = next(dep for dep in manifest['dependencies'] if dep['name'] == 'ffmpeg')
        self.assertFalse(ffmpeg['default-features'])
        self.assertEqual(ffmpeg['features'], ['avcodec', 'avformat'])
        self.assertIn({'name': 'pkgconf', 'host': True}, manifest['dependencies'])
        self.assertIn('--host-triplet x64-windows-static', windows)
        self.assertIn('$env:PKG_CONFIG_PATH', windows)
        self.assertIn('$env:PKG_CONFIG', windows)
        self.assertIn('-C target-feature=+crt-static', windows)


if __name__ == '__main__':
    unittest.main()
