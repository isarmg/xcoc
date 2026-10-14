#!/usr/bin/env python3
"""Build a final checksummed desktop archive with its actual runtime inventory."""
import argparse
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',required=True,type=Path)
    parser.add_argument('--native-work',required=True,type=Path)
    parser.add_argument('--target',required=True)
    parser.add_argument('--asset',required=True)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();output=args.output.resolve(strict=True)
    spec=importlib.util.spec_from_file_location('xcoc_desktop',ROOT/'scripts/prepare-desktop-inventory.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory(prefix='xcoc-desktop-delivery-') as temporary:
        private=Path(temporary);stage=private/'payload';stage.mkdir(mode=0o755)
        windows=args.target.endswith('windows-msvc')
        runtime='target/release/'+('xcoc.exe' if windows else 'xcoc')
        destination=stage/runtime;destination.parent.mkdir(mode=0o755,parents=True)
        shutil.copyfile(args.binary,destination);destination.chmod(0o755)
        for relative in ('README.md','LICENSE-APACHE','packaging/native/NOTICE.txt'):
            path=stage/relative;path.parent.mkdir(mode=0o755,parents=True,exist_ok=True)
            shutil.copyfile(ROOT/relative,path);path.chmod(0o644)
        if args.target.endswith('unknown-linux-gnu'):
            for name,mode in [('install.sh',0o755),('xcoc.service',0o644)]:
                path=stage/'packaging/linux'/name;path.parent.mkdir(mode=0o755,parents=True,exist_ok=True)
                shutil.copyfile(ROOT/'packaging/linux'/name,path);path.chmod(mode)
        shutil.copytree(output/'native-licenses',stage/'dist/native-licenses')
        companion=output/(args.asset+'-relink-source.tar.gz')
        shutil.copyfile(companion,stage/'dist'/companion.name)
        for path in (stage/'dist').rglob('*'):
            path.chmod(0o755 if path.is_dir() else 0o644)
        module.prepare(stage,args.native_work,args.target,runtime,build_input_root=private/'build-inputs')
        subprocess.run([sys.executable,str(ROOT/'scripts/verify-release-inventory.py'),
                        '--stage',str(stage),'--target',args.target],check=True,
                       env=module.inventory_module().clean_environment())
        archive=output/(args.asset+('.zip' if windows else '.tar.gz'))
        if windows:
            with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED) as package:
                for path in sorted(stage.rglob('*')):
                    if path.is_file():package.write(path,path.relative_to(stage).as_posix())
        else:
            with tarfile.open(archive,'x:gz') as package:package.add(stage,arcname='.')
        checksum=module.inventory_module().file_binding(output,{'path':archive.name,'archive_entry':None})['sha256']
        archive.with_name(archive.name+'.sha256').write_text(checksum+'  '+archive.name+'\n')


if __name__=='__main__':main()
