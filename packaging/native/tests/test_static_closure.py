import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC=importlib.util.spec_from_file_location('native_static_closure',Path(__file__).resolve().parents[1]/'static-closure.py')
closure=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(closure)


@unittest.skipUnless(shutil.which('cc') and shutil.which('ar') and shutil.which('pkg-config'), 'native linker tools')
class StaticClosureTests(unittest.TestCase):
    def test_actual_static_link_resolves_transitive_tls_compression_and_keeps_notices(self):
        with tempfile.TemporaryDirectory(prefix='xcoc-static-closure-') as temporary:
            root=Path(temporary);prefix=root/'install';dependency=root/'system'
            library=dependency/'usr/lib';library.mkdir(parents=True)
            metadata=dependency/'pc';metadata.mkdir()
            media=prefix/'lib/pkgconfig';media.mkdir(parents=True)
            def archive(name,body,destination):
                source=root/(name+'.c');source.write_text(body)
                output=root/(name+'.o')
                subprocess.run(['cc','-c',str(source),'-o',str(output)],check=True,capture_output=True)
                subprocess.run(['ar','rcs',str(destination/('lib'+name+'.a')),str(output)],check=True,capture_output=True)
            for name in ('avformat','avcodec','avutil'):
                archive(name,'int '+name+'_fixture(void) { return 0; }',prefix/'lib')
                (media/('lib'+name+'.pc')).write_text(f'Name: {name}\nDescription: fixture\nVersion: 1.0.0\nLibs: -L{prefix}/lib -l{name}'+(' -lssl -lcrypto' if name=='avformat' else '')+'\nRequires.private: \n')
            archive('ssl','extern int compression_fixture(void); int tls_fixture(void) { return compression_fixture(); }',library)
            archive('crypto','int crypto_fixture(void) { return 0; }',library)
            archive('z','int compression_fixture(void) { return 0; }',library)
            (metadata/'openssl.pc').write_text(f'Name: openssl\nDescription: fixture\nVersion: 1.0.0\nLibs: -L{library} -lssl -lcrypto\nRequires.private: zlib\n')
            (metadata/'zlib.pc').write_text(f'Name: zlib\nDescription: fixture\nVersion: 1.0.0\nLibs: -L{library} -lz\n')
            for package in ('libssl-dev','zlib1g-dev'):
                directory=dependency/'usr/share/doc'/package;directory.mkdir(parents=True)
                (directory/'copyright').write_text(package+' actual fixture license\n')
            environment={'LIBRARY_PATH':str(library),'PKG_CONFIG_LIBDIR':str(metadata)}
            with patch.dict(os.environ,environment):
                closure.stage(prefix,dependency)
                command=['pkg-config','--libs','--static','libavformat','libavcodec','libavutil']
                resolved=subprocess.check_output(command,env=dict(os.environ,PKG_CONFIG_PATH=str(media)),text=True)
            self.assertIn('-lz',resolved)
            self.assertEqual((prefix/'lib/libz.a').read_bytes(),(library/'libz.a').read_bytes())
            self.assertEqual((prefix/'share/xcoc-native/zlib1g-dev-copyright.txt').read_bytes(),(dependency/'usr/share/doc/zlib1g-dev/copyright').read_bytes())
            program=root/'main.c';program.write_text('extern int tls_fixture(void); int main(void) { return tls_fixture(); }')
            # Only the copied release prefix is searched. The hidden provider
            # compression symbol must resolve from the staged static archive.
            libraries=['-lavformat','-lavcodec','-lavutil','-lssl','-lcrypto','-lz']
            output=root/'actual-link'
            subprocess.run(['cc',str(program),'-L'+str(prefix/'lib'),'-Wl,-Bstatic',*libraries,'-Wl,-Bdynamic','-o',str(output)],check=True,capture_output=True)
            subprocess.run([str(output)],check=True)
            dynamic=subprocess.check_output(['readelf','--dynamic',str(output)],text=True)
            self.assertNotIn('libz.so',dynamic)
            self.assertNotIn('libssl.so',dynamic)
            before=(media/'libavformat.pc').read_bytes()
            closure.openssl_requirements(media)
            self.assertEqual(before,(media/'libavformat.pc').read_bytes())


if __name__=='__main__':unittest.main()
