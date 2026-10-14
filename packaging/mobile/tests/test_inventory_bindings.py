import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

SPEC=importlib.util.spec_from_file_location('mobile_inventory',Path(__file__).resolve().parents[3]/'scripts/package-mobile-inventory.py')
inventory=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(inventory)


class MobileInventoryBindingsTests(unittest.TestCase):
    def test_final_apk_and_bundle_bind_actual_native_and_every_dex_entry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);header=bytearray(64);header[:6]=b'\x7fELF\x02\x01';struct.pack_into('<H',header,18,183)
            for suffix,prefix,dex in (('.apk','lib/',''),('.aab','base/lib/','base/dex/')):
                path=root/('final'+suffix)
                with zipfile.ZipFile(path,'w') as archive:
                    archive.writestr(prefix+'arm64-v8a/libxcoc_mobile_ffi.so',header)
                    archive.writestr(dex+'classes.dex',b'actual final DEX fixture')
                    archive.writestr(dex+'classes2.dex',b'actual second DEX fixture')
                before=path.read_bytes()
                native,managed=inventory.bindings(path,'xcoc','android')
                self.assertEqual(native,[{'path':path.name,'archive_entry':prefix+'arm64-v8a/libxcoc_mobile_ffi.so'}])
                self.assertEqual({item['archive_entry'] for item in managed},{dex+'classes.dex',dex+'classes2.dex'})
                self.assertEqual(path.read_bytes(),before,'inventory must not alter the final signed package')

    def test_runtime_architecture_and_absent_dex_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'invalid.apk'
            with zipfile.ZipFile(path,'w') as archive:
                archive.writestr('lib/arm64-v8a/libxszc_mobile.so',b'not an actual native executable')
                archive.writestr('classes.dex',b'dex')
            with self.assertRaisesRegex(ValueError,'actual little-endian ARM64'):
                inventory.bindings(path,'xszc','android')

    def test_ipa_and_archive_bind_the_current_arm64_app_without_repacking(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);header=bytearray(32);header[:4]=b'\xcf\xfa\xed\xfe';struct.pack_into('<I',header,4,0x0100000c)
            for prefix in ('Payload/XcocCamera.app/','XcocCamera.xcarchive/Products/Applications/XcocCamera.app/'):
                path=root/('final.ipa' if prefix.startswith('Payload/') else 'final.xcarchive.zip')
                with zipfile.ZipFile(path,'w') as archive:
                    archive.writestr(prefix+'Info.plist',plistlib.dumps({'CFBundleExecutable':'XcocCamera'}))
                    archive.writestr(prefix+'XcocCamera',header)
                before=path.read_bytes()
                native,managed=inventory.bindings(path,'xcoc','ios-device')
                self.assertEqual(native,[{'path':path.name,'archive_entry':prefix+'XcocCamera'}])
                self.assertEqual(managed,[])
                self.assertEqual(before,path.read_bytes())


if __name__=='__main__':unittest.main()
