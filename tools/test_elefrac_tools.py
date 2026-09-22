#!/usr/bin/env python3
import hashlib
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent / 'elefrac-tools'))
try:
    import efpak
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


if __name__ == '__main__':
    unittest.main()
