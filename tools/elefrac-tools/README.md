# Deferred client/server packaging tools

These standalone Elefrac tools are retained as references for the client/server
packaging work. They are not called by the modkit editor. Their release layout
and asset classification still contain Elefrac-specific rules and need review
before integration.

| File | Purpose |
|------|---------|
| `paksets.py` | Compose client/server balance, cosmetics and registry pak sets |
| `registry.py` | Read and write AssetRegistry.bin; used by paksets |
| `efpak.py` | Read and write cooked paks; used by paksets and registry |

Run `python3 tools/elefrac-tools/paksets.py --help` for the standalone options.
Requires Python 3 and `cryptography`.

The old balance scripts, release example, binary property/text editing helpers,
path defaults and project-specific translation tables have been removed.
Use the editor's **Tools → Localization** and **Tools → Batch Recipes** for the
supported workflows; see [the workflow guide](../../docs/mod-workflows.md).
