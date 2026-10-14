#!/usr/bin/env python3
"""Verify the product C declarations against the exact locked shared Rust ABI."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tomllib

ROOT=Path(__file__).resolve().parents[1]


def main():
    manifest=tomllib.loads((ROOT/'crates/mobile-ffi/Cargo.toml').read_text())
    dependency=manifest['dependencies']['xcsc']
    revision=dependency['rev'];version=dependency['version'].removeprefix('=')
    source=f"git+{dependency['git']}?rev={revision}#{revision}"
    metadata=json.loads(subprocess.check_output(['cargo','metadata','--locked','--format-version','1'],cwd=ROOT))
    matches=[package for package in metadata['packages']
             if package['name']=='xcsc' and package['version']==version and package['source']==source]
    if len(matches)!=1:raise SystemExit('expected one exact locked xcsc ABI source')
    foundation=Path(matches[0]['manifest_path']).resolve().parent
    subprocess.run([sys.executable,str(foundation/'tools/ffi_header.py'),
        '--product-source','crates/mobile-ffi/src/lib.rs','--guard','XCOC_RUST_H',
        '--check','ffi/include/XcocRust.h'],cwd=ROOT,check=True)


if __name__=='__main__':main()
