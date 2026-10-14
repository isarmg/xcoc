"""Exercise private tool imports with real Python modules and late imports."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[3] / 'scripts/release-inventory.py'
SPEC = importlib.util.spec_from_file_location('xcoc_inventory_import_tests', SCRIPT)
inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inventory)


class ToolImportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='xcoc-tool-imports-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tools = self.root / 'tools'
        self.scripts = self.tools / 'scripts'
        self.scripts.mkdir(parents=True)
        self.before_path = list(sys.path)
        self.foreign = types.ModuleType('upstream_licenses')
        self.foreign.marker = 'foreign caller module'
        self.previous = sys.modules.get('upstream_licenses')
        self.previous_sqlite = sys.modules.get('sqlite_receipt')
        sys.modules['upstream_licenses'] = self.foreign
        self.addCleanup(self.restore_foreign)
        (self.scripts / 'upstream_licenses.py').write_text("marker = 'reviewed tool source'\n")
        (self.scripts / 'sqlite_receipt.py').write_text(
            "def record(*args, **kwargs):\n"
            "    from upstream_licenses import marker\n"
            "    if marker != 'reviewed tool source': raise ValueError('foreign helper')\n"
            "    return {'name': 'actual selected SQLite fixture'}\n")
        # This matches the pinned package.py import-time path insertion.
        (self.scripts / 'package.py').write_text(
            "import sys\nfrom pathlib import Path\n"
            "sys.path.insert(0, str(Path(__file__).resolve().parent))\n")
        (self.scripts / 'sbom.py').write_text(
            "import json\nimport package\n"
            "def produce_runtime_cargo_bom(source, manifest, name, stage, label, local_sources, **kwargs):\n"
            "    from upstream_licenses import marker\n"
            "    if marker != 'reviewed tool source': raise ValueError('foreign helper')\n"
            "    path = stage / 'share/runtime-sbom.cdx.json'\n"
            "    path.write_text(json.dumps({'metadata': {'component': {'bom-ref': 'urn:fixture:runtime'}}, 'components': [{'name': 'libsqlite3-sys'}]}))\n"
            "    return path\n")
        (self.scripts / 'release_sbom.py').write_text(
            "import json\n"
            "def finalize(stage, boms, receipt, *args, **kwargs):\n"
            "    from upstream_licenses import marker\n"
            "    if marker != 'reviewed tool source': raise ValueError('foreign helper')\n"
            "    value = json.loads(receipt.read_text())\n"
            "    if value['components'] != [{'name': 'actual selected SQLite fixture'}]: raise ValueError('missing native receipt')\n"
            "    if not value['runtime_roots'][0]['files'][0]['sha256']: raise ValueError('missing final file binding')\n"
            "    path = stage / 'share/release-sbom.cdx.json'\n"
            "    path.write_text(json.dumps(value))\n"
            "    return path\n")

    def restore_foreign(self):
        if self.previous is None:
            sys.modules.pop('upstream_licenses', None)
        else:
            sys.modules['upstream_licenses'] = self.previous

    def test_generate_keeps_late_producer_native_and_finalizer_imports_in_reviewed_source(self):
        stage = self.root / 'stage'
        stage.mkdir()
        (stage / 'xcoc.exe').write_bytes(b'public runtime file binding fixture')
        source = self.root / 'source'
        source.mkdir()
        (source / 'Cargo.toml').write_text('[package]\nname="fixture"\nversion="1.0.0"\n')
        with patch.object(inventory, 'checkout_tools', return_value=self.tools), \
             patch.object(inventory, 'exported_source', return_value=source), \
             patch.object(inventory, 'run', side_effect=lambda command, *args: 'a' * 40 if command[1] == 'rev-parse' else ''):
            result = inventory.generate(stage, product='xcoc', version='1.0.0', revision='a' * 40,
                target='x86_64-pc-windows-msvc', root_name='xcoc',
                runtime_files=[{'path': 'xcoc.exe', 'archive_entry': None}])
        self.assertTrue(result.is_file())
        self.assertEqual(sys.path, self.before_path)
        self.assertIs(sys.modules['upstream_licenses'], self.foreign)
        self.assertIs(sys.modules.get('sqlite_receipt'), self.previous_sqlite)

    def test_exception_restores_path_and_foreign_helper_identity(self):
        with self.assertRaisesRegex(RuntimeError, 'fixture interruption'):
            with inventory.tool_imports(self.tools):
                helper = importlib.import_module('upstream_licenses')
                self.assertEqual(helper.marker, 'reviewed tool source')
                sys.path.insert(0, 'fixture provider mutation')
                raise RuntimeError('fixture interruption')
        self.assertEqual(sys.path, self.before_path)
        self.assertIs(sys.modules['upstream_licenses'], self.foreign)

    def test_unscoped_or_foreign_tool_path_and_changed_source_pin_are_rejected(self):
        other = self.root / 'other-tools'
        (other / 'scripts').mkdir(parents=True)
        with self.assertRaises(ValueError):
            inventory.load_tool('sbom', self.tools)
        with inventory.tool_imports(self.tools):
            with self.assertRaises(ValueError):
                inventory.load_tool('../sbom', self.tools)
            with self.assertRaises(ValueError):
                inventory.load_tool('sbom', other)
        identity = self.root / 'build-tools-source.json'
        with patch.object(inventory, 'ROOT', self.root):
            for value in ({'repository': 'https://example.invalid/tools.git', 'revision': 'a' * 40},
                          {'repository': inventory.TOOLS_REPOSITORY, 'revision': 'main'}):
                identity.write_text(json.dumps(value))
                with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'exact official Git revision'):
                    inventory.tools_identity()


if __name__ == '__main__':
    unittest.main()
