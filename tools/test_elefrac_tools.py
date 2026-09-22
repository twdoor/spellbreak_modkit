#!/usr/bin/env python3
import contextlib
import hashlib
import io
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent / 'elefrac-tools'))
try:
    import efpak
    import propdump
    import balance_loc
except ImportError:
    efpak = None


@unittest.skipIf(efpak is None, 'EF scripts require cryptography')
class ElefracToolsTest(unittest.TestCase):
    def test_small_pak(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'small.pak'
            efpak.write_pak(path, [('g3/a', b'x')], compress=False)
            p = efpak.Pak(path)
            try:
                self.assertEqual(p.get('g3/a'), b'x')
            finally:
                p.f.close()

    def test_v8_repack(self):
        with tempfile.TemporaryDirectory() as folder:
            src, dst = Path(folder) / 'v8.pak', Path(folder) / 'out.pak'
            payload = b'v8 sample payload' * 30
            rec = struct.pack('<QQQB', 0, len(payload), len(payload), 0) + hashlib.sha1(payload).digest() + struct.pack('<BI', 0, 0)
            index = bytearray()
            efpak.wr_fstr(index, '../../../')
            index += struct.pack('<I', 1)
            efpak.wr_fstr(index, 'g3/sample.bin')
            index += rec
            src.write_bytes(rec + payload + index + struct.pack('<IIQQ20s', efpak.MAGIC, 8, len(rec)+len(payload), len(index), hashlib.sha1(index).digest()) + bytes(128))
            efpak.repack(src, dst)
            p = efpak.Pak(dst)
            try:
                self.assertEqual(p.ver, 3)
                self.assertEqual(p.get('g3/sample.bin'), payload)
            finally:
                p.f.close()

    def test_bool_guid_not_modified(self):
        a = SimpleNamespace(names=['Enabled', 'BoolProperty', 'None'], x=bytearray(struct.pack('<iiiiiiBB', 0, 0, 1, 0, 0, 0, 1, 1) + bytes(range(16)) + struct.pack('<ii', 2, 0)))
        before = bytes(a.x)
        reader = propdump.Reader(a)
        reader.props(0, len(a.x), 'Test')
        _, typ, off, _ = reader.out[0]
        propdump.patch_value(a, off, typ, False)
        self.assertEqual([i for i, (x,y) in enumerate(zip(before, a.x)) if x != y], [24])

    def test_missing_translation_fails_check(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'strings.json').write_text('[{"src":"Damage 10"}]')
            with patch.object(balance_loc, 'I18N', folder), patch.object(balance_loc, 'CULTURES', ['en', 'de']), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(balance_loc.cmd_check(), 1)


if __name__ == '__main__':
    unittest.main()
