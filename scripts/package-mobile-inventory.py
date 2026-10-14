#!/usr/bin/env python3
"""Inventory final mobile archives and their separate SHA256 release metadata."""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import struct
import tempfile
import tomllib
import zipfile

ROOT=Path(__file__).resolve().parents[1]


def common():
    spec=importlib.util.spec_from_file_location('mobile_release_inventory',ROOT/'scripts/release-inventory.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def bindings(path,product,platform):
    native=[];managed=[]
    with zipfile.ZipFile(path) as archive:
        names=archive.namelist()
        if len(names)!=len(set(names)):raise ValueError('mobile archive has duplicate entries')
        if platform=='android':
            library='libxcoc_mobile_ffi.so' if product=='xcoc' else 'libxszc_mobile.so'
            expected=('base/lib/' if path.suffix=='.aab' else 'lib/')+'arm64-v8a/'+library
            if expected not in names:raise ValueError('final mobile archive lacks its actual Rust library')
            with archive.open(expected) as source:header=source.read(64)
            if len(header)<20 or header[:6]!=b'\x7fELF\x02\x01' or struct.unpack_from('<H',header,18)[0]!=183:
                raise ValueError('Android Rust runtime must be an actual little-endian ARM64 ELF')
            native.append({'path':path.name,'archive_entry':expected})
            for name in names:
                parts=name.split('/')
                if path.suffix=='.aab':selected=len(parts)==3 and parts[:2]==['base','dex']
                else:selected=len(parts)==1
                if selected and parts[-1].startswith('classes') and parts[-1].endswith('.dex'):
                    managed.append({'path':path.name,'archive_entry':name})
            if not managed:raise ValueError('Android runtime graph has no final DEX artifact')
        else:
            app='XcocCamera.app' if product=='xcoc' else 'Xszc.app'
            infos=[name for name in names if name.endswith('/'+app+'/Info.plist') or name==app+'/Info.plist']
            if len(infos)!=1:raise ValueError('mobile archive has no unique application bundle')
            info=plistlib.loads(archive.read(infos[0]));executable=info.get('CFBundleExecutable')
            if not isinstance(executable,str) or Path(executable).name!=executable:
                raise ValueError('mobile application executable is invalid')
            entry=infos[0].removesuffix('Info.plist')+executable
            with archive.open(entry) as source:header=source.read(32)
            if len(header)<8 or header[:4]!=b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I',header,4)[0]!=0x0100000c:
                raise ValueError('iOS Rust host must be an actual ARM64 Mach-O executable')
            native.append({'path':path.name,'archive_entry':entry})
    return native,managed


def package(artifacts,output,platform,gradle_export=None):
    module=common();environment=module.clean_environment()
    profile=tomllib.loads((ROOT/'xcsc-client.toml').read_text());product=profile['product_id']
    if product not in ('xcoc','xszc'):raise ValueError('unknown mobile product')
    manifest=tomllib.loads((ROOT/'Cargo.toml').read_text())
    version=manifest['package']['version'] if product=='xcoc' else manifest['workspace']['package']['version']
    revision=module.run(['git','rev-parse','HEAD'],ROOT,environment)
    target={'android':'aarch64-linux-android','ios-device':'aarch64-apple-ios',
            'ios-simulator':'aarch64-apple-ios-sim'}[platform]
    root_name='xcoc-mobile-ffi' if product=='xcoc' else 'xszc-mobile'
    output=Path(output)
    if not output.is_absolute() or output.exists():raise ValueError('mobile inventory output must be a new absolute directory')
    if platform=='android' and gradle_export is None:raise ValueError('Android requires the actual release runtime resolution export')
    output.mkdir(mode=0o755,parents=True)
    native=[];managed=[]
    for source in artifacts:
        source=Path(source)
        if source.is_symlink() or not source.is_file() or (output/source.name).exists():
            raise ValueError('mobile package source must be a unique physical file')
        destination=output/source.name;shutil.copyfile(source,destination)
        current_native,current_managed=bindings(destination,product,platform)
        native.extend(current_native);managed.extend(current_managed)
    graphs=[]
    if platform=='android':
        with tempfile.TemporaryDirectory(prefix=product+'-android-runtime-') as temporary:
            tools=module.checkout_tools(Path(temporary).resolve(strict=True)/'tools',environment)
            with module.tool_imports(tools):
                producer=module.load_tool('gradle_sbom',tools)
                bom=producer.produce(json.loads(Path(gradle_export).read_text(encoding='utf-8')),output,product,version,revision)
        graphs.append({'bom':str(bom),'files':managed})
    module.generate(output,product=product,version=version,revision=revision,target=target,
        root_name=root_name,runtime_files=native,manifest_relative='crates/mobile-ffi/Cargo.toml',
        additional_runtime_graphs=graphs)
    # The final package and every sidecar byte are fixed before the separate
    # release SHA256 inventory; native platform signatures already belong to
    # the selected signed or explicitly unsigned input artifact.
    return output


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package',action='append',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--platform',choices=['android','ios-device','ios-simulator'],required=True)
    parser.add_argument('--gradle-export',type=Path)
    args=parser.parse_args();package(args.package,args.output,args.platform,args.gradle_export)


if __name__=='__main__':main()
