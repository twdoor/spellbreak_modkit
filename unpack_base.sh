#!/bin/bash
# ============================================================
#  Spellbreak Base Pak Unpacker
#  Extracts the base game .pak so you can grab files to modify.
#  You only need to run this once (or when the game updates).
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
U4PAK="$SCRIPT_DIR/u4pak/u4pak.py"
CONFIG="$SCRIPT_DIR/config.json"

if [ ! -f "$CONFIG" ]; then
    echo -e "${RED}ERROR: config.json not found. Run: python3 mod_manager.py${NC}"
    exit 1
fi
GAME_DIR=$(python3 -c "import json;c=json.load(open('$CONFIG'));print(c.get('game_dir',''))" 2>/dev/null)
if [ -z "$GAME_DIR" ]; then
    echo -e "${RED}ERROR: game_dir not set in config.json. Run: python3 mod_manager.py${NC}"
    exit 1
fi
EXTRACT_DIR="$HOME/spellbreak-unpacked"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

PAKS_DIR="$GAME_DIR/g3/Content/Paks"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Spellbreak Base Pak Unpacker${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Find the main game pak
MAIN_PAK=""
for pak in "$PAKS_DIR"/*.pak; do
    # Skip our mod paks
    if [[ "$pak" == *"_P.pak" ]]; then
        continue
    fi
    if [ -f "$pak" ]; then
        MAIN_PAK="$pak"
        echo -e "Found: ${BLUE}$(basename "$pak")${NC} ($(du -h "$pak" | cut -f1))"
    fi
done

if [ -z "$MAIN_PAK" ]; then
    echo -e "${RED}No .pak files found in: $PAKS_DIR${NC}"
    echo "Check your GAME_DIR setting."
    exit 1
fi

echo ""

if [ "$1" = "--list" ] || [ "$1" = "-l" ]; then
    echo -e "${YELLOW}Listing contents (this may take a moment)...${NC}"
    python3 "$U4PAK" list "$MAIN_PAK" 2>/dev/null
    exit 0
fi

if [ "$1" = "--search" ] || [ "$1" = "-s" ]; then
    if [ -z "$2" ]; then
        echo "Usage: $0 --search <pattern>"
        echo "Example: $0 --search DataTable"
        exit 1
    fi
    echo -e "${YELLOW}Searching for '$2'...${NC}"
    python3 "$U4PAK" list "$MAIN_PAK" 2>/dev/null | grep -i "$2"
    exit 0
fi

echo -e "${YELLOW}Extracting to: $EXTRACT_DIR${NC}"
echo -e "(This may take a while for large paks...)"
echo ""

mkdir -p "$EXTRACT_DIR"
cd "$EXTRACT_DIR"
python3 "$U4PAK" unpack "$MAIN_PAK" -v

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Unpacked successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  Files are in: $EXTRACT_DIR"
    echo ""
    echo -e "  ${YELLOW}To mod a file:${NC}"
    echo -e "  1. Find it in $EXTRACT_DIR/g3/Content/..."
    echo -e "  2. Copy BOTH the .uasset and .uexp to the same path under:"
    echo -e "     $HOME/spellbreak-mods/g3/Content/..."
    echo -e "  3. Edit with UAssetGUI / UAssetEditor"
    echo -e "  4. Run pack_mod.sh"
else
    echo ""
    echo -e "${RED}Unpacking failed. The pak may use a newer version.${NC}"
    echo -e "Try listing contents instead: $0 --list"
fi
