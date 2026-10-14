#!/usr/bin/env python3
"""Stage the real pkg-config static dependency closure, including TLS providers."""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

OS_LIBRARIES = {'c', 'm', 'dl', 'pthread', 'rt', 'gcc', 'gcc_s'}
FFMPEG_LIBRARIES = {'avformat', 'avcodec', 'avutil'}
NOTICE_PACKAGES = {'ssl': 'libssl-dev', 'crypto': 'libssl-dev', 'z': 'zlib1g-dev',
                   'zstd': 'libzstd-dev'}


def openssl_requirements(directory):
    for path in sorted(directory.glob('*.pc')):
        contents=path.read_text()
        if not re.search(r'(?:^|\s)-l(?:ssl|crypto)(?:\s|$)', contents):
            continue
        lines=contents.splitlines()
        for index,line in enumerate(lines):
            if line.startswith('Requires.private:'):
                requirements=line.removeprefix('Requires.private:').strip()
                if not re.search(r'(?:^|[\s,])openssl(?:[\s,]|$)', requirements):
                    lines[index]='Requires.private: '+requirements+(', ' if requirements else '')+'openssl'
                break
        else:lines.append('Requires.private: openssl')
        path.write_text('\n'.join(lines)+'\n')


def stage(prefix, dependency_root=Path('/')):
    prefix=Path(prefix).resolve(strict=True)
    directory=prefix/'lib/pkgconfig'
    openssl_requirements(directory)
    environment=dict(os.environ,PKG_CONFIG_PATH=str(directory))
    output=subprocess.check_output(['pkg-config','--libs','--static',
        'libavformat','libavcodec','libavutil'],env=environment,text=True,timeout=30)
    libraries={flag[2:] for flag in shlex.split(output) if flag.startswith('-l')}
    if not FFMPEG_LIBRARIES <= libraries:
        raise ValueError('resolved static graph is missing a required media library')
    notices=prefix/'share/xcoc-native';notices.mkdir(parents=True,exist_ok=True)
    for name in sorted(libraries-OS_LIBRARIES-FFMPEG_LIBRARIES):
        if not re.fullmatch('[A-Za-z0-9_.+-]+',name) or name not in {*NOTICE_PACKAGES, 'atomic'}:
            raise ValueError('review the license notice for the resolved static dependency')
        filename='lib'+name+'.a'
        found=subprocess.check_output(['cc','-print-file-name='+filename],text=True,timeout=30).strip()
        archive=Path(found).resolve()
        if found==filename or not archive.is_file():
            raise ValueError('missing resolved static dependency archive')
        shutil.copy2(archive,prefix/'lib'/filename)
        if name == 'atomic':
            owners=subprocess.check_output(['dpkg-query','-S',str(archive)],text=True,timeout=30).splitlines()
            owners=[line.rpartition(': ')[0] for line in owners if line.rpartition(': ')[2]==str(archive)]
            if len(owners)!=1 or not re.fullmatch(r'libgcc-[0-9]+-dev(?::[a-z0-9]+)?',owners[0]):
                raise ValueError('static atomic archive has no actual compiler development package owner')
            package=owners[0].split(':',1)[0]
        else:
            package=NOTICE_PACKAGES[name]
        notice_root=dependency_root if dependency_root!=Path('/') and archive.is_relative_to(dependency_root) else Path('/')
        copyright=notice_root/'usr/share/doc'/package/'copyright'
        if not copyright.is_file():
            raise ValueError('missing resolved static dependency license notice')
        shutil.copy2(copyright,notices/(package+'-copyright.txt'))


if __name__=='__main__':
    if len(sys.argv)!=2:raise SystemExit('Usage: static-closure.py INSTALL_PREFIX')
    stage(Path(sys.argv[1]),Path(os.environ.get('XCOC_NATIVE_DEPENDENCY_ROOT','/')).resolve(strict=True))
