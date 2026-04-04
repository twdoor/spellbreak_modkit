#!/usr/bin/env python3
"""
UAsset Editor — TUI tree editor for Unreal Engine asset files.
A Linux-native alternative to UAssetGUI.

Usage:
  python3 uasset_editor.py <file.uasset>   (opens, edits, saves back to .uasset)
  python3 uasset_editor.py <file.json>      (edits raw UAssetAPI JSON)

Requires uasset_tool.py --setup for .uasset support.
"""

import curses
import json
import sys
import os
import copy
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()

# ── Tree Node ──────────────────────────────────────────────────

class Node:
    """A node in the tree view."""
    __slots__ = ('label', 'value', 'children', 'expanded', 'depth',
                 'editable', 'path', 'parent', 'value_type')

    def __init__(self, label, value=None, children=None, depth=0,
                 editable=False, path=None, parent=None, value_type=None,
                 expanded=False):
        self.label = label
        self.value = value
        self.children = children or []
        self.expanded = expanded
        self.depth = depth
        self.editable = editable
        self.path = path or []
        self.parent = parent
        self.value_type = value_type


def build_tree(data):
    """Build a tree from UAssetAPI JSON data."""
    root = Node("Root", children=[], expanded=True)

    # NameMap
    nm = data.get("NameMap", [])
    nm_node = Node(f"NameMap [{len(nm)}]", depth=0, path=["NameMap"])
    for i, name in enumerate(nm):
        nm_node.children.append(
            Node(f"[{i}]", value=name, depth=1, editable=True,
                 path=["NameMap", i], parent=nm_node, value_type="string"))
    root.children.append(nm_node)

    # Imports
    imports = data.get("Imports", [])
    imp_node = Node(f"Imports [{len(imports)}]", depth=0, path=["Imports"])
    for i, imp in enumerate(imports):
        cn = imp.get("ClassName", "?")
        on = imp.get("ObjectName", "?")
        imp_child = Node(f"[{i}] {on} ({cn})", depth=1, path=["Imports", i])
        for k, v in imp.items():
            if k == "$type": continue
            imp_child.children.append(
                Node(k, value=v, depth=2, editable=isinstance(v, (str, int, float, bool)),
                     path=["Imports", i, k], parent=imp_child,
                     value_type=type(v).__name__))
        imp_node.children.append(imp_child)
    root.children.append(imp_node)

    # Exports
    exports = data.get("Exports", [])
    exp_node = Node(f"Exports [{len(exports)}]", depth=0, path=["Exports"])
    for i, exp in enumerate(exports):
        on = exp.get("ObjectName", f"Export_{i}")
        exp_child = Node(f"[{i}] {on}", depth=1, path=["Exports", i])

        # Export metadata
        meta_node = Node("Export Info", depth=2, path=["Exports", i, "_meta"])
        for k in ("ObjectName", "OuterIndex", "ClassIndex", "SuperIndex",
                   "ObjectGuid", "ObjectFlags", "SerialSize", "SerialOffset"):
            v = exp.get(k)
            if v is not None:
                meta_node.children.append(
                    Node(k, value=v, depth=3, editable=isinstance(v, (str, int, float)),
                         path=["Exports", i, k], parent=meta_node,
                         value_type=type(v).__name__))
        if meta_node.children:
            exp_child.children.append(meta_node)

        # Export Data (properties)
        props = exp.get("Data", [])
        if props:
            data_node = Node(f"Data [{len(props)}]", depth=2,
                             path=["Exports", i, "Data"])
            for j, prop in enumerate(props):
                pnode = build_property_node(prop, depth=3,
                                           path=["Exports", i, "Data", j])
                data_node.children.append(pnode)
            exp_child.children.append(data_node)

        exp_node.children.append(exp_child)
    root.children.append(exp_node)

    return root


def build_property_node(prop, depth=0, path=None):
    """Build a tree node for a UAssetAPI property."""
    ptype_full = prop.get("$type", "")
    ptype = ptype_full.split(".")[-1].split(",")[0] if ptype_full else "?"
    ptype = ptype.replace("PropertyData", "")
    pname = prop.get("Name", "?")
    val = prop.get("Value")

    node = Node(f"{pname}", depth=depth, path=path)

    # Simple editable values
    if isinstance(val, (str, int, float, bool)):
        node.value = val
        node.editable = True
        node.value_type = f"{ptype}:{type(val).__name__}"
        node.label = f"{pname} ({ptype})"
        return node

    # Struct/Array with nested properties
    if isinstance(val, list):
        node.label = f"{pname} ({ptype}) [{len(val)}]"
        for i, item in enumerate(val):
            if isinstance(item, dict) and "Name" in item:
                child = build_property_node(item, depth=depth+1,
                                           path=(path or []) + ["Value", i])
                node.children.append(child)
            elif isinstance(item, dict):
                child = Node(f"[{i}]", depth=depth+1,
                             path=(path or []) + ["Value", i])
                for k, v in item.items():
                    if k == "$type": continue
                    child.children.append(
                        Node(k, value=v, depth=depth+2,
                             editable=isinstance(v, (str, int, float, bool)),
                             path=(path or []) + ["Value", i, k],
                             parent=child, value_type=type(v).__name__))
                node.children.append(child)
            else:
                node.children.append(
                    Node(f"[{i}]", value=item, depth=depth+1,
                         editable=isinstance(item, (str, int, float, bool)),
                         path=(path or []) + ["Value", i], parent=node,
                         value_type=type(item).__name__))
        return node

    # Dict value (like SoftObjectPath)
    if isinstance(val, dict):
        node.label = f"{pname} ({ptype})"
        for k, v in val.items():
            if k == "$type": continue
            if isinstance(v, dict):
                dchild = Node(k, depth=depth+1, path=(path or []) + ["Value", k])
                for dk, dv in v.items():
                    if dk == "$type": continue
                    dchild.children.append(
                        Node(dk, value=dv, depth=depth+2,
                             editable=isinstance(dv, (str, int, float, bool)),
                             path=(path or []) + ["Value", k, dk],
                             parent=dchild, value_type=type(dv).__name__))
                node.children.append(dchild)
            else:
                node.children.append(
                    Node(k, value=v, depth=depth+1,
                         editable=isinstance(v, (str, int, float, bool)),
                         path=(path or []) + ["Value", k], parent=node,
                         value_type=type(v).__name__))
        return node

    # Null or other
    if val is None:
        node.label = f"{pname} ({ptype})"
        node.value = "null"
        node.editable = False
    else:
        node.label = f"{pname} ({ptype})"
        node.value = val
        node.editable = isinstance(val, (str, int, float, bool))
        node.value_type = type(val).__name__

    # Add non-Value fields that are interesting
    for k in ("EnumType", "StructType", "ArrayType", "Flags",
              "HistoryType", "Namespace", "CultureInvariantString"):
        v = prop.get(k)
        if v is not None and v != "None":
            node.children.append(
                Node(k, value=v, depth=depth+1,
                     editable=isinstance(v, (str, int, float, bool)),
                     path=(path or []) + [k], parent=node,
                     value_type=type(v).__name__))

    return node


def flatten_tree(node, result=None, visible_only=True):
    """Flatten tree to list of visible nodes."""
    if result is None:
        result = []
    for child in node.children:
        result.append(child)
        if child.expanded and child.children:
            flatten_tree(child, result, visible_only)
    return result


def set_json_value(data, path, value):
    """Set a value in the JSON data at the given path."""
    obj = data
    for key in path[:-1]:
        obj = obj[key]
    last = path[-1]

    # Try to preserve type
    old = obj[last]
    if isinstance(old, int) and not isinstance(old, bool):
        try: value = int(value)
        except: pass
    elif isinstance(old, float):
        try: value = float(value)
        except: pass
    elif isinstance(old, bool):
        value = value.lower() in ("true", "1", "yes")

    obj[last] = value


# ── TUI Editor ─────────────────────────────────────────────────

C_NORM=1; C_SEL=2; C_KEY=3; C_VAL=4; C_TYPE=5; C_HDR=6; C_EDIT=7; C_DIM=8; C_TREE=9; C_MOD=10

def init_colors():
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(C_NORM, -1, -1)
    curses.init_pair(C_SEL, curses.COLOR_BLACK, curses.COLOR_CYAN)
    curses.init_pair(C_KEY, curses.COLOR_CYAN, -1)
    curses.init_pair(C_VAL, curses.COLOR_GREEN, -1)
    curses.init_pair(C_TYPE, curses.COLOR_YELLOW, -1)
    curses.init_pair(C_HDR, curses.COLOR_CYAN, -1)
    curses.init_pair(C_EDIT, curses.COLOR_BLACK, curses.COLOR_YELLOW)
    curses.init_pair(C_DIM, curses.COLOR_WHITE, -1)
    curses.init_pair(C_TREE, curses.COLOR_WHITE, -1)
    curses.init_pair(C_MOD, curses.COLOR_RED, -1)


def run_editor(stdscr, source, display_name=None, save_callback=None):
    """
    Main editor loop.
    source: either a file path (str) to load JSON from, or a dict of already-parsed data.
    display_name: shown in title bar
    save_callback: called with (data) on save. If None, writes JSON to source path.
    """
    init_colors()
    curses.curs_set(0)

    if isinstance(source, dict):
        data = source
        source_path = None
    else:
        source_path = source
        with open(source) as f:
            data = json.load(f)

    if display_name is None:
        display_name = Path(source_path).name if source_path else "untitled"

    root = build_tree(data)
    for child in root.children:
        child.expanded = False

    cursor = 0
    scroll = 0
    search_term = ""
    status = f"Loaded: {display_name}"
    modified = False

    while True:
        h, w = stdscr.getmaxyx()
        hdr_h = 2
        ftr_h = 2
        body_h = h - hdr_h - ftr_h

        flat = flatten_tree(root)

        # Clamp cursor
        if len(flat) == 0:
            cursor = 0
        else:
            cursor = max(0, min(cursor, len(flat) - 1))

        # Scroll
        if cursor < scroll:
            scroll = cursor
        if cursor >= scroll + body_h:
            scroll = cursor - body_h + 1

        stdscr.erase()

        # ── Header ──
        title = f" UAsset Editor — {display_name} "
        if modified: title += "[MODIFIED] "
        stdscr.attron(curses.color_pair(C_HDR) | curses.A_BOLD)
        stdscr.addnstr(0, 0, "─" * w, w-1)
        tx = max(0, (w - len(title)) // 2)
        stdscr.addnstr(0, tx, title, w - tx - 1)
        stdscr.attroff(curses.color_pair(C_HDR) | curses.A_BOLD)

        if search_term:
            stdscr.attron(curses.color_pair(C_TYPE))
            stdscr.addnstr(1, 1, f"Search: {search_term}", w-2)
            stdscr.attroff(curses.color_pair(C_TYPE))

        # ── Body ──
        for i in range(body_h):
            idx = scroll + i
            if idx >= len(flat):
                break
            node = flat[idx]
            y = hdr_h + i
            sel = idx == cursor

            # Build display line
            indent = "  " * node.depth
            if node.children:
                arrow = "▼ " if node.expanded else "▶ "
            else:
                arrow = "  "

            label = node.label
            val_str = ""
            if node.value is not None and not node.children:
                vs = str(node.value)
                if len(vs) > w // 2:
                    vs = vs[:w//2 - 3] + "..."
                val_str = f" = {vs}"

            line = f"{indent}{arrow}{label}"
            max_label = w - len(val_str) - 2
            if len(line) > max_label:
                line = line[:max_label-3] + "..."

            if sel:
                stdscr.attron(curses.color_pair(C_SEL))
                stdscr.addnstr(y, 0, " " * (w-1), w-1)
                stdscr.addnstr(y, 0, line, w-1)
                if val_str:
                    vx = len(line)
                    stdscr.addnstr(y, vx, val_str[:w-vx-1], w-vx-1)
                stdscr.attroff(curses.color_pair(C_SEL))
            else:
                # Tree lines
                stdscr.attron(curses.color_pair(C_TREE))
                stdscr.addnstr(y, 0, indent, w-1)
                stdscr.attroff(curses.color_pair(C_TREE))

                # Arrow
                ax = len(indent)
                if node.children:
                    stdscr.attron(curses.color_pair(C_DIM))
                    stdscr.addnstr(y, ax, arrow, w-ax-1)
                    stdscr.attroff(curses.color_pair(C_DIM))
                ax += len(arrow)

                # Label
                stdscr.attron(curses.color_pair(C_KEY))
                stdscr.addnstr(y, ax, label, w-ax-1)
                stdscr.attroff(curses.color_pair(C_KEY))

                # Value
                if val_str:
                    vx = ax + len(label)
                    vc = C_MOD if node.editable else C_VAL
                    stdscr.attron(curses.color_pair(C_VAL))
                    stdscr.addnstr(y, vx, val_str[:w-vx-1], w-vx-1)
                    stdscr.attroff(curses.color_pair(C_VAL))

        # ── Footer ──
        fy = h - ftr_h
        stdscr.attron(curses.color_pair(C_DIM))
        stdscr.addnstr(fy, 0, "─" * w, w-1)
        stdscr.attroff(curses.color_pair(C_DIM))

        if status:
            sc = C_VAL if "Saved" in status or "Loaded" in status else C_TYPE
            stdscr.attron(curses.color_pair(sc))
            stdscr.addnstr(fy, 1, status[:w-2], w-2)
            stdscr.attroff(curses.color_pair(sc))

        # Node count + position
        pos = f" {cursor+1}/{len(flat)} "
        stdscr.attron(curses.color_pair(C_DIM))
        stdscr.addnstr(fy, w-len(pos)-1, pos, len(pos))
        stdscr.attroff(curses.color_pair(C_DIM))

        ctrls = " ↑↓ nav │ ←→ fold │ ENTER edit │ / search │ n next │ S save │ Q quit "
        stdscr.attron(curses.color_pair(C_TYPE))
        stdscr.addnstr(fy+1, 0, ctrls[:w-1], w-1)
        stdscr.attroff(curses.color_pair(C_TYPE))

        stdscr.refresh()

        # ── Input ──
        try:
            key = stdscr.getch()
        except curses.error:
            continue
        if key == -1:
            continue

        if not flat:
            if key in (ord("q"), ord("Q")):
                break
            continue

        node = flat[cursor]

        # Navigation
        if key == curses.KEY_UP:
            cursor = max(0, cursor - 1)
        elif key == curses.KEY_DOWN:
            cursor = min(len(flat) - 1, cursor + 1)
        elif key == curses.KEY_PPAGE:  # Page Up
            cursor = max(0, cursor - body_h)
        elif key == curses.KEY_NPAGE:  # Page Down
            cursor = min(len(flat) - 1, cursor + body_h)
        elif key == curses.KEY_HOME:
            cursor = 0
        elif key == curses.KEY_END:
            cursor = len(flat) - 1

        # Expand/collapse
        elif key == curses.KEY_RIGHT or key == ord("l"):
            if node.children and not node.expanded:
                node.expanded = True
            elif node.children and node.expanded:
                # Move to first child
                cursor = min(cursor + 1, len(flat) - 1)
        elif key == curses.KEY_LEFT or key == ord("h"):
            if node.expanded and node.children:
                node.expanded = False
            # else: could go to parent but complex with flat list

        # Toggle expand
        elif key == ord(" "):
            if node.children:
                node.expanded = not node.expanded

        # Edit value
        elif key in (curses.KEY_ENTER, 10, 13):
            if node.editable and node.path:
                new_val = edit_value(stdscr, node, h, w)
                if new_val is not None:
                    try:
                        set_json_value(data, node.path, new_val)
                        node.value = new_val
                        modified = True
                        status = f"Changed: {node.label} = {new_val}"
                    except Exception as e:
                        status = f"Error: {e}"
            elif node.children:
                node.expanded = not node.expanded
            else:
                status = "Not editable"

        # Search
        elif key == ord("/"):
            search_term = get_input(stdscr, "Search: ", h, w)
            if search_term:
                # Find next match from current position
                found = find_next(flat, cursor, search_term)
                if found >= 0:
                    cursor = found
                    status = f"Found: {search_term}"
                else:
                    # Try expanding all and searching
                    expand_all(root)
                    flat = flatten_tree(root)
                    found = find_next(flat, 0, search_term)
                    if found >= 0:
                        cursor = found
                        status = f"Found: {search_term} (expanded tree)"
                    else:
                        status = f"Not found: {search_term}"
        elif key == ord("n"):
            if search_term:
                flat = flatten_tree(root)
                found = find_next(flat, cursor + 1, search_term)
                if found >= 0:
                    cursor = found
                else:
                    found = find_next(flat, 0, search_term)
                    if found >= 0:
                        cursor = found
                        status = "Wrapped to top"
                    else:
                        status = "No more matches"

        # Save
        elif key in (ord("s"), ord("S")):
            try:
                if save_callback:
                    ok, msg = save_callback(data)
                    if ok:
                        modified = False
                        status = f"Saved: {display_name}"
                    else:
                        status = f"Save error: {msg}"
                elif source_path:
                    with open(source_path, 'w') as f:
                        json.dump(data, f, indent=2)
                    modified = False
                    status = f"Saved: {display_name}"
                else:
                    status = "No save target"
            except Exception as e:
                status = f"Save error: {e}"

        # Quit
        elif key in (ord("q"), ord("Q")):
            if modified:
                stdscr.attron(curses.color_pair(C_EDIT))
                stdscr.addnstr(h-2, 1, " Unsaved changes! Press Q again to quit, S to save ", w-2)
                stdscr.attroff(curses.color_pair(C_EDIT))
                stdscr.refresh()
                k2 = stdscr.getch()
                if k2 in (ord("q"), ord("Q")):
                    break
                elif k2 in (ord("s"), ord("S")):
                    try:
                        if save_callback:
                            save_callback(data)
                        elif source_path:
                            with open(source_path, 'w') as f:
                                json.dump(data, f, indent=2)
                        modified = False
                        status = "Saved"
                    except Exception as e:
                        status = f"Save error: {e}"
            else:
                break

        # Expand/collapse all
        elif key == ord("e"):
            expand_all(root)
            status = "Expanded all"
        elif key == ord("c"):
            collapse_all(root)
            cursor = 0
            status = "Collapsed all"


def edit_value(stdscr, node, h, w):
    """Inline edit a value."""
    y = h - 2
    prompt = f" Edit {node.label}: "
    old_val = str(node.value)

    stdscr.attron(curses.color_pair(C_EDIT))
    stdscr.addnstr(y, 0, " " * (w-1), w-1)
    stdscr.addnstr(y, 0, prompt, w-1)
    stdscr.attroff(curses.color_pair(C_EDIT))
    stdscr.refresh()

    curses.echo()
    curses.curs_set(1)
    try:
        # Pre-fill with old value
        stdscr.addnstr(y, len(prompt), old_val, w - len(prompt) - 2)
        stdscr.move(y, len(prompt))
        inp = stdscr.getstr(y, len(prompt), w - len(prompt) - 2)
        val = inp.decode("utf-8", errors="replace").strip()
        if val == "":
            return None
        return val
    except Exception:
        return None
    finally:
        curses.noecho()
        curses.curs_set(0)


def get_input(stdscr, prompt, h, w):
    """Get text input from user."""
    y = h - 2
    stdscr.attron(curses.color_pair(C_EDIT))
    stdscr.addnstr(y, 0, " " * (w-1), w-1)
    stdscr.addnstr(y, 0, f" {prompt}", w-1)
    stdscr.attroff(curses.color_pair(C_EDIT))
    stdscr.refresh()

    curses.echo()
    curses.curs_set(1)
    try:
        inp = stdscr.getstr(y, len(prompt) + 1, w - len(prompt) - 3)
        return inp.decode("utf-8", errors="replace").strip()
    except Exception:
        return ""
    finally:
        curses.noecho()
        curses.curs_set(0)


def find_next(flat, start, term):
    """Find next node matching search term."""
    term_lower = term.lower()
    for i in range(start, len(flat)):
        node = flat[i]
        if term_lower in node.label.lower():
            return i
        if node.value is not None and term_lower in str(node.value).lower():
            return i
    return -1


def expand_all(node):
    if node.children:
        node.expanded = True
        for c in node.children:
            expand_all(c)

def collapse_all(node):
    if node.children:
        node.expanded = False
        for c in node.children:
            collapse_all(c)


# ── Main ───────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return

    filepath = Path(sys.argv[1]).resolve()

    if not filepath.exists():
        print(f"File not found: {filepath}")
        return

    if filepath.suffix == ".json":
        # Direct JSON editing (legacy mode)
        try:
            with open(filepath) as f:
                json.load(f)
        except json.JSONDecodeError as e:
            print(f"Invalid JSON: {e}")
            return
        curses.wrapper(lambda s: run_editor(s, str(filepath)))

    elif filepath.suffix == ".uasset":
        # Native uasset editing — no intermediate files
        try:
            from uasset_tool import read_uasset, write_uasset, TOOL_DLL
        except ImportError:
            print("uasset_tool.py not found in the same directory.")
            return

        if not TOOL_DLL.exists():
            print("UAsset converter not set up. Run:")
            print("  python3 uasset_tool.py --setup")
            return

        print(f"Loading {filepath.name}...")
        data, msg = read_uasset(str(filepath))
        if data is None:
            print(f"Failed to load: {msg}")
            return
        print("Ready.")

        def save_uasset(edited_data):
            """Pipe edited data directly back to .uasset."""
            return write_uasset(str(filepath), edited_data)

        curses.wrapper(lambda s: run_editor(
            s, data,
            display_name=filepath.name,
            save_callback=save_uasset,
        ))
    else:
        print(f"Unsupported file type: {filepath.suffix}")
        print("Supported: .uasset, .json")


if __name__ == "__main__":
    main()
