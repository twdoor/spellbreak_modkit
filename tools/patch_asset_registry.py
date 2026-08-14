#!/usr/bin/env python3
"""Development entry point for the editor's bundled registry patcher."""

from pathlib import Path
import runpy


runpy.run_path(
    str(Path(__file__).resolve().parents[1]
        / "spellbreak_uasset_editor" / "asset_registry" / "patch_asset_registry.py"),
    run_name="__main__",
)
