#!/usr/bin/env python3
"""Bind the final desktop payload to actual Cargo and native build inputs."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import tomllib

ROOT=Path(__file__).resolve().parents[1]


def inventory_module():
    spec=importlib.util.spec_from_file_location('xcoc_release_inventory',ROOT/'scripts/release-inventory.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


def prepare(stage,work,target,runtime_path,*,components=(),build_input_root=None):
    inventory=inventory_module();environment=inventory.clean_environment()
    revision=inventory.run(['git','rev-parse','HEAD'],ROOT,environment)
    version=tomllib.loads((ROOT/'Cargo.toml').read_text())['package']['version']
    stage=Path(stage).resolve(strict=True)
    build_input_root=Path(build_input_root)
    build_input_root.mkdir(mode=0o700,parents=True,exist_ok=True)
    material=build_input_root/'packaging/native/sources.json'
    material.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    if material.exists():raise ValueError('native source identity would overwrite a build input')
    shutil.copyfile(ROOT/'packaging/native/sources.json',material)
    files=[inventory.file_binding(stage,{'path':runtime_path,'archive_entry':None})]
    with tempfile.TemporaryDirectory(prefix='xcoc-native-origins-') as temporary:
        tools=inventory.checkout_tools(Path(temporary).resolve(strict=True)/'tools',environment)
        native=inventory.load_tool('static_native_receipt',tools)
        captured=native.record(Path(work),stage,target_files=files,build_input_root=build_input_root,
                               target=target,inventory_relative='share')
    return inventory.generate(stage,product='xcoc',version=version,revision=revision,target=target,
        root_name='xcoc',runtime_files=[{'path':runtime_path,'archive_entry':None}],
        components=[*captured,*components],build_input_root=build_input_root)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('stage','native-work','build-input-root'):
        parser.add_argument('--'+name,required=True,type=Path)
    parser.add_argument('--target',required=True)
    parser.add_argument('--runtime-path',required=True)
    parser.add_argument('--external-components',type=Path)
    args=parser.parse_args();prepare(args.stage,args.native_work,args.target,args.runtime_path,
        components=json.loads(args.external_components.read_text()) if args.external_components else (),
        build_input_root=args.build_input_root)


if __name__=='__main__':main()
