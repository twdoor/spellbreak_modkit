#!/usr/bin/env python3
"""
Spellbreak Mod Manager — Terminal UI
Navigate mods, toggle them, pack, watch for changes, launch.
"""

import curses
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

# ── PATHS ──────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent.resolve()
U4PAK = SCRIPT_DIR / "u4pak" / "u4pak.py"
CONFIG_FILE = SCRIPT_DIR / "config.json"
STATE_FILE = SCRIPT_DIR / ".mod_state.json"

DEFAULT_CONFIG = {
    "game_dir": "",
    "mods_dir": "",
    "launch_cmd": "",
}


# ── CONFIG ─────────────────────────────────────────────────────

def load_config():
    if CONFIG_FILE.exists():
        try:
            return {**DEFAULT_CONFIG, **json.loads(CONFIG_FILE.read_text())}
        except (json.JSONDecodeError, IOError):
            pass
    return dict(DEFAULT_CONFIG)

def save_config(cfg):
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))

def paks_dir(cfg):
    return Path(cfg["game_dir"]) / "g3" / "Content" / "Paks"

def mods_dir(cfg):
    return Path(cfg["mods_dir"])


# ── SETUP ──────────────────────────────────────────────────────

def run_setup():
    cfg = load_config()
    C, G, Y, D, B, X = "\033[96m", "\033[92m", "\033[93m", "\033[2m", "\033[1m", "\033[0m"

    print(f"\n{C}{'─'*50}{X}")
    print(f"{C}{B}  Spellbreak Mod Manager — Setup{X}")
    print(f"{C}{'─'*50}{X}\n")

    print(f"{B}1. Game directory{X} {D}(contains g3/ folder){X}")
    print(f"   {D}Current: {cfg['game_dir']}{X}")
    v = input(f"   Path [{cfg['game_dir']}]: ").strip()
    if v: cfg["game_dir"] = os.path.expanduser(v)
    if (Path(cfg["game_dir"]) / "g3").exists():
        print(f"   {G}✓ Found g3/{X}")
    else:
        print(f"   {Y}⚠ g3/ not found{X}")

    print(f"\n{B}2. Mods directory{X} {D}(each mod = subfolder with g3/){X}")
    print(f"   {D}Current: {cfg['mods_dir']}{X}")
    v = input(f"   Path [{cfg['mods_dir']}]: ").strip()
    if v: cfg["mods_dir"] = os.path.expanduser(v)
    mp = Path(cfg["mods_dir"])
    if not mp.exists():
        mp.mkdir(parents=True, exist_ok=True)
        print(f"   {G}✓ Created{X}")
    else:
        mc = sum(1 for d in mp.iterdir() if d.is_dir() and (d/"g3").exists())
        print(f"   {G}✓ Found {mc} mod(s){X}")

    print(f"\n{B}3. Launch command{X}")
    print(f"   {D}The exact command you use to start the game.{X}")
    print(f"   {D}Examples:{X}")
    print(f"     {D}steam steam://rungameid/1399780{X}")
    print(f"     {D}/path/to/Spellbreak.exe{X}")
    print(f"     {D}(leave blank if you launch manually){X}")
    print(f"   {D}Current: {cfg['launch_cmd'] or '(none)'}{X}")
    v = input(f"   Command [{cfg['launch_cmd'] or 'none'}]: ").strip()
    if v and v.lower() != "none":
        cfg["launch_cmd"] = v
    elif v.lower() == "none":
        cfg["launch_cmd"] = ""

    save_config(cfg)
    print(f"\n{G}{'─'*50}{X}")
    print(f"{G}{B}  Config saved!{X}")
    print(f"{G}{'─'*50}{X}")
    print(f"\n  Run:        {B}python3 {__file__}{X}")
    print(f"  Reconfigure: {B}python3 {__file__} --setup{X}\n")
    return cfg


# ── STATE ──────────────────────────────────────────────────────

def load_state():
    if STATE_FILE.exists():
        try: return json.loads(STATE_FILE.read_text())
        except: pass
    return {}

def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2))


# ── MODS ───────────────────────────────────────────────────────

ASSET_EXTS = {".uasset", ".uexp", ".ubulk", ".umap"}

def discover_mods(md):
    mods = []
    if not md.exists(): return mods
    for entry in sorted(md.iterdir()):
        if not entry.is_dir(): continue
        g3 = entry / "g3"
        if not g3.exists(): continue
        assets = [f for f in g3.rglob("*") if f.suffix in ASSET_EXTS]
        if assets:
            size = sum(f.stat().st_size for f in g3.rglob("*") if f.is_file())
            mods.append({"name": entry.name, "path": entry,
                         "file_count": len(assets), "size": size})
    return mods

def get_mod_files(mod_path):
    g3 = mod_path / "g3"
    if not g3.exists(): return []
    return [str(f.relative_to(mod_path)) for f in sorted(g3.rglob("*")) if f.is_file()]

def fmt_size(b):
    if b < 1024: return f"{b} B"
    if b < 1048576: return f"{b/1024:.1f} KB"
    return f"{b/1048576:.1f} MB"


# ── PACK ───────────────────────────────────────────────────────

def find_sig(pd):
    if not pd.exists(): return None
    for f in sorted(pd.iterdir()):
        if f.suffix == ".sig" and not f.name.startswith("zzz_mods"): return f
    return None

def pack_mods(enabled, pd, log=None):
    if not enabled: return False, "No mods enabled"
    if not pd.exists(): return False, f"Paks dir missing: {pd}"
    if not U4PAK.exists(): return False, f"u4pak missing: {U4PAK}"

    with tempfile.TemporaryDirectory(prefix="sb_") as tmp:
        mg = Path(tmp) / "merged"
        mg.mkdir()
        for mod in enabled:
            g3 = mod["path"] / "g3"
            if not g3.exists(): continue
            for src in g3.rglob("*"):
                if not src.is_file(): continue
                if src.suffix == ".json": continue  # JSON sidecars stay out of the pak
                rel = src.relative_to(mod["path"])
                dst = mg / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
                if log: log(f"  + {rel}")

        pak = pd / "zzz_mods_P.pak"
        if pak.exists(): pak.unlink()
        if log: log(""); log("Packing...")

        r = subprocess.run(
            [sys.executable, str(U4PAK), "pack", "--archive-version=3",
             "--mount-point=../../../", str(pak), "g3/"],
            cwd=str(mg), capture_output=True, text=True)
        if r.returncode != 0:
            return False, f"Pack failed: {r.stderr.strip() or r.stdout.strip()}"

        # Sig file
        sig = pak.with_suffix(".sig")
        if sig.exists(): sig.unlink()
        existing = find_sig(pd)
        if existing:
            shutil.copy2(existing, sig)
            if log: log(f"Sig: {existing.name}")
        else:
            sig.touch()
            if log: log("Sig: empty (no template found)")

        return True, f"Packed {pak.name} + .sig ({fmt_size(pak.stat().st_size)})"

def remove_pak(pd):
    removed = []
    for ext in (".pak", ".sig"):
        f = pd / f"zzz_mods_P{ext}"
        if f.exists(): f.unlink(); removed.append(ext)
    if removed: return True, f"Removed zzz_mods_P ({', '.join(removed)})"
    return False, "No mod pak to remove"


# ── LAUNCH ─────────────────────────────────────────────────────

def launch_game(cfg, log=None):
    cmd = cfg.get("launch_cmd", "").strip()
    if not cmd:
        return False, "No launch command set — press S to configure"
    if log: log(f"Running: {cmd}")
    try:
        subprocess.Popen(cmd, shell=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True, f"Launched: {cmd}"
    except Exception as e:
        return False, f"Launch failed: {e}"


# ── TUI ────────────────────────────────────────────────────────

class TUI:
    HDR = 4; FTR = 3
    C_NORM=1; C_SEL=2; C_ON=3; C_OFF=4; C_HDR=5; C_OK=6; C_ERR=7; C_ACC=8; C_DIM=9; C_FIL=10

    def __init__(self, cfg):
        self.cfg = cfg
        self.pd = paks_dir(cfg)
        self.md = mods_dir(cfg)
        self.mods = []; self.state = {}
        self.cur = 0; self.scroll = 0
        self.mode = "list"; self.dscroll = 0; self.hscroll = 0
        self.status = ""; self.status_ok = True
        self.log = []
        self.watching = False; self.wpacks = 0

    def colors(self):
        curses.start_color(); curses.use_default_colors()
        for i, (fg, bg) in enumerate([
            (-1,-1), (curses.COLOR_BLACK, curses.COLOR_CYAN),
            (curses.COLOR_GREEN,-1), (curses.COLOR_RED,-1),
            (curses.COLOR_CYAN,-1), (curses.COLOR_GREEN,-1),
            (curses.COLOR_RED,-1), (curses.COLOR_YELLOW,-1),
            (curses.COLOR_WHITE,-1), (curses.COLOR_BLUE,-1)
        ], 1):
            curses.init_pair(i, fg, bg)

    def refresh_mods(self):
        self.mods = discover_mods(self.md)
        names = {m["name"] for m in self.mods}
        self.state = {k:v for k,v in self.state.items() if k in names}
        for m in self.mods:
            if m["name"] not in self.state: self.state[m["name"]] = False

    def header(self, s):
        h, w = s.getmaxyx()
        s.attron(curses.color_pair(self.C_HDR)|curses.A_BOLD)
        s.addnstr(0, 0, "─"*w, w-1)
        t = " SPELLBREAK MOD MANAGER "
        s.addnstr(0, max(0,(w-len(t))//2), t, w-1)
        s.attroff(curses.color_pair(self.C_HDR)|curses.A_BOLD)

        ec = sum(1 for m in self.mods if self.state.get(m["name"]))
        info = f" {len(self.mods)} mods · {ec} enabled"
        s.attron(curses.color_pair(self.C_DIM)); s.addnstr(1, 0, info, w-1)
        s.attroff(curses.color_pair(self.C_DIM))

        pk = self.pd / "zzz_mods_P.pak"
        if pk.exists():
            sz = fmt_size(pk.stat().st_size)
            sg = "+sig" if (self.pd/"zzz_mods_P.sig").exists() else "NO SIG"
            pi = f"  pak: {sz} [{sg}]"
            s.attron(curses.color_pair(self.C_ON))
            s.addnstr(1, len(info), pi, w-len(info)-1)
            s.attroff(curses.color_pair(self.C_ON))

        if self.watching:
            wt = f" [WATCH #{self.wpacks}]"
            wx = w - len(wt) - 1
            if wx > 0:
                s.attron(curses.color_pair(self.C_ACC)|curses.A_BOLD)
                s.addnstr(1, wx, wt, len(wt))
                s.attroff(curses.color_pair(self.C_ACC)|curses.A_BOLD)

        s.attron(curses.color_pair(self.C_DIM))
        s.addnstr(2, 0, "─"*w, w-1)
        s.attroff(curses.color_pair(self.C_DIM))

    def footer(self, s):
        h, w = s.getmaxyx()
        y = h - self.FTR
        s.attron(curses.color_pair(self.C_DIM)); s.addnstr(y, 0, "─"*w, w-1)
        s.attroff(curses.color_pair(self.C_DIM))

        if self.status:
            c = self.C_OK if self.status_ok else self.C_ERR
            s.attron(curses.color_pair(c)); s.addnstr(y+1, 1, self.status[:w-2], w-2)
            s.attroff(curses.color_pair(c))

        ctrls = {
            "list":   " ↑↓ nav │ SPACE toggle │ ENTER browse │ P pack │ L launch │ W watch │ H help │ S setup │ Q quit",
            "detail": " ↑↓ scroll │ ESC back │ SPACE toggle │ Q quit",
            "pack":   " Press any key...",
            "help":   " ↑↓ scroll │ ESC/H back",
        }.get(self.mode, "")
        s.attron(curses.color_pair(self.C_ACC))
        s.addnstr(y+2, 0, ctrls[:w-1], w-1)
        s.attroff(curses.color_pair(self.C_ACC))

    def draw_list(self, s):
        h, w = s.getmaxyx(); ls = self.HDR; lh = h - self.HDR - self.FTR
        if not self.mods:
            s.attron(curses.color_pair(self.C_DIM))
            s.addnstr(ls+1, 2, f"No mods in: {self.md}", w-4)
            s.addnstr(ls+3, 2, "Each mod = folder with g3/Content/...", w-4)
            s.addnstr(ls+4, 2, "S=setup  R=refresh", w-4)
            s.attroff(curses.color_pair(self.C_DIM)); return

        if self.cur < self.scroll: self.scroll = self.cur
        if self.cur >= self.scroll + lh: self.scroll = self.cur - lh + 1

        for i in range(lh):
            idx = self.scroll + i
            if idx >= len(self.mods): break
            m = self.mods[idx]; y = ls + i
            sel = idx == self.cur; on = self.state.get(m["name"], False)
            tog = "●" if on else "○"; nm = m["name"]
            ex = f"  {m['file_count']} files · {fmt_size(m['size'])}"
            if sel:
                s.attron(curses.color_pair(self.C_SEL))
                s.addnstr(y, 0, " "*(w-1), w-1)
                s.addnstr(y, 1, f" {tog} {nm}", w-2)
                r = w-5-len(nm)
                if r > 0: s.addnstr(y, 4+len(nm), ex[:r], r)
                s.attroff(curses.color_pair(self.C_SEL))
            else:
                tc = self.C_ON if on else self.C_OFF
                s.attron(curses.color_pair(tc)); s.addnstr(y, 1, f" {tog} ", 4)
                s.attroff(curses.color_pair(tc))
                s.addnstr(y, 4, nm, w-5)
                r = w-5-len(nm)
                if r > 0:
                    s.attron(curses.color_pair(self.C_DIM))
                    s.addnstr(y, 4+len(nm), ex[:r], r)
                    s.attroff(curses.color_pair(self.C_DIM))

    def draw_detail(self, s):
        h, w = s.getmaxyx()
        if self.cur >= len(self.mods): return
        m = self.mods[self.cur]; on = self.state.get(m["name"], False)
        files = get_mod_files(m["path"])
        cs = self.HDR; ch = h - self.HDR - self.FTR

        s.attron(curses.color_pair(self.C_ACC)|curses.A_BOLD)
        s.addnstr(cs, 2, m["name"], w-4)
        s.attroff(curses.color_pair(self.C_ACC)|curses.A_BOLD)
        st = "ENABLED" if on else "DISABLED"
        sc = self.C_ON if on else self.C_OFF
        s.attron(curses.color_pair(sc))
        s.addnstr(cs, 3+len(m["name"]), f"[{st}]", w-4-len(m["name"]))
        s.attroff(curses.color_pair(sc))

        s.attron(curses.color_pair(self.C_DIM))
        s.addnstr(cs+1, 2, f"{m['file_count']} files · {fmt_size(m['size'])} · open .uasset files in the Godot editor"[:w-4], w-4)
        s.addnstr(cs+2, 2, "─"*(w-4), w-4)
        s.attroff(curses.color_pair(self.C_DIM))

        fh = ch - 3; mx = max(0, len(files)-fh)
        self.dscroll = max(0, min(self.dscroll, mx))
        for i in range(fh):
            fi = self.dscroll + i
            if fi >= len(files): break
            f = files[fi]
            col = self.C_FIL if f.endswith(".uasset") else self.C_DIM
            s.attron(curses.color_pair(col))
            s.addnstr(cs+3+i, 3, f[:w-5], w-5)
            s.attroff(curses.color_pair(col))

    def draw_pack(self, s):
        h, w = s.getmaxyx(); cs = self.HDR; ch = h - self.HDR - self.FTR
        s.attron(curses.color_pair(self.C_ACC)|curses.A_BOLD)
        s.addnstr(cs, 2, "Packing...", w-4)
        s.attroff(curses.color_pair(self.C_ACC)|curses.A_BOLD)
        start = max(0, len(self.log)-(ch-2))
        for i, line in enumerate(self.log[start:start+ch-2]):
            s.attron(curses.color_pair(self.C_DIM))
            s.addnstr(cs+2+i, 3, line[:w-5], w-5)
            s.attroff(curses.color_pair(self.C_DIM))

    HELP = [
        ("h", "WORKFLOW"),
        ("", "  Watcher auto-starts on launch."),
        ("", "  1. Toggle mods with SPACE"),
        ("", "  2. ENTER on a mod → browse files → ENTER on .uasset → editor"),
        ("", "  3. Edit values, press S to save back to .uasset"),
        ("", "  4. Watcher auto-packs, restart game to see changes"),
        ("", ""),
        ("h", "EDITING"),
        ("", "  Open .uasset files directly in the Godot editor."),
        ("", "  Save → watcher detects the change and auto-packs."),
        ("", "  Use 'tojson'/'fromjson' commands only if you need"),
        ("", "  to inspect or share the JSON representation."),
        ("", ""),
        ("h", "UE4 caches assets in memory. A game restart is"),
        ("h", "required for changes to take effect."),
        ("", ""),
        ("h", "─── CONSOLE COMMANDS (~ key in-game) ───"),
        ("", ""),
        ("h", "MATCH"),
        ("a", "  StartMatch              Start match"),
        ("a", "  StartInfiniteMatch      Match that won't end"),
        ("a", "  SetAllowRoundEnd 0/1    Toggle match ending"),
        ("a", "  StopCircles             Remove storm"),
        ("a", "  CloseCircle             Force circle close"),
        ("", ""),
        ("h", "TESTING"),
        ("a", "  God                     Invincible"),
        ("a", "  FastCooldowns           Fast abilities"),
        ("a", "  Superspeed 5            Speed (1=normal, 10=max)"),
        ("a", "  Die                     Kill self"),
        ("a", "  LevelUpCharacterClass   Level up + unlock"),
        ("a", "  ToggleDebugCamera       Free camera"),
        ("a", "  ToggleHUD               Hide/show HUD"),
        ("a", "  Teleport                Hold T on map, click"),
        ("", ""),
        ("h", "BOTS"),
        ("a", "  SetNumMatchBots 10      Bot count (before start)"),
        ("a", "  SpawnMatchBot           Spawn bot near you"),
        ("a", "  SetNoMatchBotAggro true Passive bots"),
        ("a", "  SetMatchBotDifficulty 0 0=VEasy 1=Easy 2=Med 3=Hard"),
        ("", ""),
        ("h", "ITEMS"),
        ("a", "  SpawnGauntlet Loot:BP_Item_Weapon_<Elem>_Tier_<1-5> 1"),
        ("a", "    Fire Ice Lightning Earth Wind Toxic"),
        ("a", "  SpawnRune Loot:BP_Item_Rune_<Name>_Tier_<1-5> 1"),
        ("a", "  SpawnAmulet Loot:BP_Item_Amulet_Tier_<1-5> 1"),
        ("a", "  SpawnBoot Loot:BP_Item_Boots_Tier_<1-5> 1"),
        ("a", "  ChooseCharacterClass CharacterClass:BP_CharacterClass_<Name>"),
        ("a", "    Frostborn Conduit Pyromancer Toxicologist Stoneshaper Tempest"),
        ("a", "  ResetCharacterPerks"),
        ("", ""),
        ("h", "DOMINION"),
        ("a", "  ToggleBoons 1/0   ToggleZones 1/0   ToggleNPCs 1/0"),
        ("a", "  SwitchTeam        SetArena <name>"),
        ("", ""),
        ("h", "─── MOD MANAGER KEYS ───"),
        ("a", "  SPACE       Toggle mod on/off"),
        ("a", "  ENTER       View mod files"),
        ("a", "  P           Pack enabled mods"),
        ("a", "  L           Launch game"),
        ("a", "  W           Toggle file watcher"),
        ("a", "  U           Remove mod pak"),
        ("a", "  R           Refresh mod list"),
        ("a", "  S           Setup / reconfigure"),
        ("a", "  H           This help"),
        ("a", "  Q           Quit"),
    ]

    def draw_help(self, s):
        h, w = s.getmaxyx(); cs = self.HDR; ch = h - self.HDR - self.FTR
        mx = max(0, len(self.HELP)-ch)
        self.hscroll = max(0, min(self.hscroll, mx))
        for i in range(ch):
            li = self.hscroll + i
            if li >= len(self.HELP): break
            kind, txt = self.HELP[li]; y = cs + i
            if kind == "h":
                s.attron(curses.color_pair(self.C_ACC)|curses.A_BOLD)
                s.addnstr(y, 2, txt[:w-4], w-4)
                s.attroff(curses.color_pair(self.C_ACC)|curses.A_BOLD)
            elif kind == "a":
                parts = txt.split("  ", 1)
                s.attron(curses.color_pair(self.C_HDR))
                s.addnstr(y, 2, parts[0][:w-4], w-4)
                s.attroff(curses.color_pair(self.C_HDR))
                if len(parts) > 1:
                    dx = 2 + len(parts[0])
                    s.attron(curses.color_pair(self.C_DIM))
                    s.addnstr(y, dx, ("  "+parts[1])[:w-dx-1], w-dx-1)
                    s.attroff(curses.color_pair(self.C_DIM))
            else:
                s.attron(curses.color_pair(self.C_NORM))
                s.addnstr(y, 2, txt[:w-4], w-4)
                s.attroff(curses.color_pair(self.C_NORM))

    # ── Main loop ──

    def run(self, stdscr):
        self.colors(); curses.curs_set(0); stdscr.timeout(100)
        self.state = load_state(); self.refresh_mods()

        # Auto-start watcher
        if any(v for v in self.state.values()):
            self.toggle_watcher()

        while True:
            try:
                stdscr.erase()
                self.header(stdscr); self.footer(stdscr)
                {"list": self.draw_list, "detail": self.draw_detail,
                 "pack": self.draw_pack, "help": self.draw_help,
                }.get(self.mode, self.draw_list)(stdscr)
                stdscr.refresh()
            except curses.error:
                pass

            try: key = stdscr.getch()
            except curses.error: continue
            if key == -1: continue

            # Global
            if key in (ord("q"), ord("Q")):
                save_state(self.state); break
            if key in (ord("p"), ord("P")):
                self.do_pack(stdscr); continue
            if key in (ord("h"), ord("H")) and self.mode != "pack":
                if self.mode == "help": self.mode = "list"
                else: self.mode = "help"; self.hscroll = 0
                continue
            if key in (ord("w"), ord("W")) and self.mode == "list":
                self.toggle_watcher(); continue
            if key in (ord("l"), ord("L")) and self.mode == "list":
                ok, msg = launch_game(self.cfg)
                self.status = msg; self.status_ok = ok; continue
            if key in (ord("s"), ord("S")) and self.mode == "list":
                save_state(self.state); curses.endwin()
                self.cfg = run_setup()
                self.pd = paks_dir(self.cfg); self.md = mods_dir(self.cfg)
                self.refresh_mods()
                stdscr = curses.initscr(); curses.noecho(); curses.cbreak()
                stdscr.keypad(True); curses.curs_set(0)
                self.colors(); stdscr.timeout(100)
                self.status = "Config updated"; self.status_ok = True
                continue

            # Mode-specific
            if self.mode == "list": self.on_list(key)
            elif self.mode == "detail": self.on_detail(key)
            elif self.mode == "help": self.on_help(key)
            elif self.mode == "pack": self.mode = "list"

    def on_list(self, key):
        if not self.mods:
            if key in (ord("r"), ord("R")):
                self.refresh_mods(); self.status = "Refreshed"; self.status_ok = True
            return
        if key == curses.KEY_UP: self.cur = max(0, self.cur-1)
        elif key == curses.KEY_DOWN: self.cur = min(len(self.mods)-1, self.cur+1)
        elif key == ord(" "):
            n = self.mods[self.cur]["name"]
            self.state[n] = not self.state.get(n, False)
            self.status = f"{n}: {'on' if self.state[n] else 'off'}"
            self.status_ok = self.state[n]; save_state(self.state)
        elif key in (curses.KEY_ENTER, 10, 13):
            self.mode = "detail"; self.dscroll = 0
        elif key in (ord("r"), ord("R")):
            self.refresh_mods(); self.status = "Refreshed"; self.status_ok = True
        elif key in (ord("u"), ord("U")):
            ok, msg = remove_pak(self.pd); self.status = msg; self.status_ok = ok

    def on_detail(self, key):
        if key in (27, curses.KEY_BACKSPACE, 127, curses.KEY_LEFT):
            self.mode = "list"
        elif key == curses.KEY_UP: self.dscroll = max(0, self.dscroll-1)
        elif key == curses.KEY_DOWN: self.dscroll += 1
        elif key == ord(" "):
            n = self.mods[self.cur]["name"]
            self.state[n] = not self.state.get(n, False)
            self.status = f"{n}: {'on' if self.state[n] else 'off'}"
            self.status_ok = self.state[n]; save_state(self.state)

    def on_help(self, key):
        if key in (27, curses.KEY_BACKSPACE, 127): self.mode = "list"
        elif key == curses.KEY_UP: self.hscroll = max(0, self.hscroll-1)
        elif key == curses.KEY_DOWN: self.hscroll += 1

    def do_pack(self, stdscr):
        self.mode = "pack"; self.log = []
        enabled = [m for m in self.mods if self.state.get(m["name"])]
        if not enabled:
            self.log.append("No mods enabled! Use SPACE to toggle.")
            self.status = "No mods enabled"; self.status_ok = False
            self._redraw(stdscr); self._wait(stdscr); self.mode = "list"; return

        self.log.append(f"Merging {len(enabled)} mod(s):")
        for m in enabled: self.log.append(f"  → {m['name']}")
        self.log.append(""); self._redraw(stdscr)

        def cb(msg): self.log.append(msg); self._redraw(stdscr)
        ok, msg = pack_mods(enabled, self.pd, log=cb)
        self.log.append(""); self.log.append(f"{'✓' if ok else '✗'} {msg}")
        if ok: self.log.append(""); self.log.append("Restart the game to load changes.")
        self.status = msg; self.status_ok = ok
        self._redraw(stdscr); self._wait(stdscr); self.mode = "list"

    def toggle_watcher(self):
        if self.watching:
            self.watching = False
            self.status = "Watcher stopped"; self.status_ok = True; return
        self.watching = True; self.wpacks = 0
        self.status = "Watcher started — auto-packs on file save"; self.status_ok = True
        save_state(self.state)

        def loop():
            def snap():
                h = hashlib.md5()
                en = {k for k,v in self.state.items() if v}
                if not self.md.exists(): return h.hexdigest()
                for e in sorted(self.md.iterdir()):
                    if not e.is_dir() or e.name not in en: continue
                    g3 = e / "g3"
                    if not g3.exists(): continue
                    for f in sorted(g3.rglob("*")):
                        if f.is_file() and f.suffix in (".uasset",".uexp",".ubulk"):
                            st = f.stat()
                            h.update(f"{f}:{st.st_size}:{st.st_mtime_ns}".encode())
                return h.hexdigest()

            last = snap()
            while self.watching:
                time.sleep(1.0)
                try:
                    cur = snap()
                    if cur != last:
                        last = cur
                        en = [m for m in self.mods if self.state.get(m["name"])]
                        if en:
                            ok, msg = pack_mods(en, self.pd)
                            self.wpacks += 1
                            self.status = f"[watch #{self.wpacks}] {msg}"
                            self.status_ok = ok
                except Exception as e:
                    self.status = f"[watch] Error: {e}"; self.status_ok = False

        threading.Thread(target=loop, daemon=True).start()

    def _redraw(self, s):
        try:
            s.erase(); self.header(s); self.footer(s); self.draw_pack(s); s.refresh()
        except curses.error: pass

    def _wait(self, s):
        self._redraw(s); s.timeout(-1); s.getch(); s.timeout(100)


# ── MAIN ───────────────────────────────────────────────────────

def main():
    if "--setup" in sys.argv or "-s" in sys.argv:
        run_setup(); return
    if not U4PAK.exists():
        print(f"u4pak not found at: {U4PAK}"); return
    if not CONFIG_FILE.exists():
        print("First time setup:\n"); cfg = run_setup()
    else: cfg = load_config()
    md = mods_dir(cfg)
    if not md.exists(): md.mkdir(parents=True, exist_ok=True)

    curses.wrapper(TUI(cfg).run)

if __name__ == "__main__":
    main()
