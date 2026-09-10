"""Clone cooked textures with relocated package names and repaired mip offsets."""
import argparse
import json
import uuid
from pathlib import Path

from unreal.uasset import Uasset


def payloads(asset):
    return [(texture.pixel_format, [(m.width, m.height, m.depth, m.data)
             for m in texture.mipmaps]) for texture in asset.get_texture_list()]


def clone_texture(source, destination, identities):
    asset = Uasset(str(source), version="4.22")
    if not asset.has_textures():
        raise ValueError("Expected a cooked texture package")
    before = payloads(asset)
    changes = 0
    for index, name in enumerate(asset.name_list):
        old = str(name)
        new = identities.get(old, old)
        if new != old:
            asset.update_name_list(index, new)
            changes += 1
    if not changes:
        raise ValueError("Texture contains no matching clone identity")
    asset.header.guid = uuid.uuid4().bytes
    asset.save(str(destination))
    reloaded = Uasset(str(destination), version="4.22")
    if payloads(reloaded) != before:
        raise ValueError("Texture payload verification failed after relocation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("identities", type=Path)
    args = parser.parse_args()
    clone_texture(args.source, args.destination,
                  json.loads(args.identities.read_text(encoding="utf-8")))


if __name__ == "__main__":
    main()
