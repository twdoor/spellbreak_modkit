#!/usr/bin/env python3
"""
Spellbreak Mod Watcher — Auto-packs when files change.

Watches for .uasset/.uexp changes and auto-packs.
Edit .uasset files directly in the Godot editor and save — no JSON step needed.

Run standalone:  python3 watch.py
Or from TUI:     press W
"""

import hashlib
import os
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
sys.path.insert(0, str(SCRIPT_DIR))

from mod_manager import (
    load_config, load_state, paks_dir, mods_dir,
    discover_mods, pack_mods, fmt_size, U4PAK, CONFIG_FILE,
)

C,G,Y,R,D,B,X = "\033[96m","\033[92m","\033[93m","\033[91m","\033[2m","\033[1m","\033[0m"


def snapshot(md, enabled):
    """Hash of all tracked binary asset files in enabled mods."""
    h = hashlib.md5()
    count = 0
    for entry in sorted(md.iterdir()) if md.exists() else []:
        if not entry.is_dir() or entry.name not in enabled: continue
        g3 = entry / "g3"
        if not g3.exists(): continue
        for f in sorted(g3.rglob("*")):
            if f.is_file() and f.suffix in (".uasset",".uexp",".ubulk",".umap"):
                st = f.stat()
                h.update(f"{f}:{st.st_size}:{st.st_mtime_ns}".encode())
                count += 1
    return h.hexdigest(), count


def do_pack(md, enabled, pd):
    all_mods = discover_mods(md)
    enabled_mods = [m for m in all_mods if m["name"] in enabled]
    if not enabled_mods: return False, "No mods"
    ok, msg = pack_mods(enabled_mods, pd, log=lambda m: None)
    return ok, msg


def watch(interval=1.0):
    cfg = load_config()
    md = mods_dir(cfg)
    pd = paks_dir(cfg)
    state = load_state()
    enabled = {k for k,v in state.items() if v}

    if not enabled:
        print(f"{R}No mods enabled! Enable mods in the TUI first.{X}")
        return
    if not md.exists():
        print(f"{R}Mods dir missing: {md}{X}")
        return

    print(f"\n{C}{'─'*55}{X}")
    print(f"{C}{B}  Spellbreak Mod Watcher{X}")
    print(f"{C}{'─'*55}{X}")
    print(f"  {D}Mods: {md}{X}")
    print(f"  {D}Paks: {pd}{X}")
    en_mods = discover_mods(md)
    en_mods = [m for m in en_mods if m["name"] in enabled]
    for m in en_mods:
        print(f"    {G}●{X} {m['name']}  {D}({m['file_count']} files){X}")

    # Initial pack
    ts = time.strftime("%H:%M:%S")
    print(f"\n  {D}[{ts}] Initial pack...{X}")
    ok, msg = do_pack(md, enabled, pd)
    if ok:
        pk = pd / "zzz_mods_P.pak"
        sz = fmt_size(pk.stat().st_size) if pk.exists() else "?"
        print(f"  {G}[{ts}] ✓ {sz}{X}")

    print(f"\n{C}{'─'*55}{X}")
    print(f"  {B}Watching...{X} {D}Ctrl+C to stop{X}")
    print(f"  {D}Edit .uasset files and save — auto-packs on change{X}")
    print(f"{C}{'─'*55}{X}\n")

    last_hash, _ = snapshot(md, enabled)
    packs = 0

    try:
        while True:
            time.sleep(interval)

            # Re-read state in case mods were toggled in TUI
            try:
                new_state = load_state()
                new_en = {k for k,v in new_state.items() if v}
                if new_en != enabled:
                    enabled = new_en
                    last_hash = ""
            except: pass

            cur_hash, _ = snapshot(md, enabled)
            if cur_hash == last_hash:
                continue
            last_hash = cur_hash
            packs += 1
            ts = time.strftime("%H:%M:%S")

            print(f"  {Y}[{ts}] Packing... (#{packs}){X}")
            ok, msg = do_pack(md, enabled, pd)
            if ok:
                pk = pd / "zzz_mods_P.pak"
                sz = fmt_size(pk.stat().st_size) if pk.exists() else "?"
                print(f"  {G}[{ts}] ✓ Packed ({sz}){X}")
            else:
                print(f"  {R}[{ts}] ✗ {msg}{X}")
            print()

    except KeyboardInterrupt:
        print(f"\n  {D}Stopped. Packed {packs} time(s).{X}\n")


if __name__ == "__main__":
    if not CONFIG_FILE.exists():
        print("Run the mod manager first: python3 mod_manager.py")
        sys.exit(1)
    watch()
