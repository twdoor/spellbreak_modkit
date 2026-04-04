#!/bin/bash
# ============================================================
#  Spellbreak Mod Packer
#  Automatically packs your loose mod files into a _P.pak
#  that the game loads with priority over base files.
# ============================================================

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
U4PAK="$SCRIPT_DIR/u4pak/u4pak.py"
CONFIG="$SCRIPT_DIR/config.json"

# Read paths from config.json (set by mod_manager.py or setup.sh)
if [ ! -f "$CONFIG" ]; then
    echo -e "${RED}ERROR: config.json not found. Run: python3 mod_manager.py${NC}"
    exit 1
fi
GAME_DIR=$(python3 -c "import json;c=json.load(open('$CONFIG'));print(c.get('game_dir',''))" 2>/dev/null)
MODS_DIR=$(python3 -c "import json;c=json.load(open('$CONFIG'));print(c.get('mods_dir',''))" 2>/dev/null)
if [ -z "$GAME_DIR" ] || [ -z "$MODS_DIR" ]; then
    echo -e "${RED}ERROR: game_dir or mods_dir not set in config.json. Run: python3 mod_manager.py${NC}"
    exit 1
fi
# ----------------------------------------

PAKS_DIR="$GAME_DIR/g3/Content/Paks"
OUTPUT_PAK="$PAKS_DIR/zzz_mods_P.pak"

# Colors for pretty output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Spellbreak Mod Packer${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check that u4pak exists
if [ ! -f "$U4PAK" ]; then
    echo -e "${RED}ERROR: u4pak.py not found at: $U4PAK${NC}"
    echo "Run setup.sh first!"
    exit 1
fi

# Check that mods directory exists
if [ ! -d "$MODS_DIR" ]; then
    echo -e "${YELLOW}Creating mods directory at: $MODS_DIR${NC}"
    mkdir -p "$MODS_DIR/g3/Content"
    echo -e "${YELLOW}Put your modified .uasset/.uexp files in:${NC}"
    echo -e "  $MODS_DIR/g3/Content/..."
    echo -e "(mirror the same folder structure from inside the .pak)"
    exit 0
fi

# Check that there are actually mod files
MOD_COUNT=$(find "$MODS_DIR/g3" -name "*.uasset" -o -name "*.uexp" -o -name "*.ubulk" 2>/dev/null | wc -l)
if [ "$MOD_COUNT" -eq 0 ]; then
    echo -e "${RED}No mod files found in $MODS_DIR/g3/${NC}"
    echo -e "Place your .uasset/.uexp files in:"
    echo -e "  $MODS_DIR/g3/Content/..."
    exit 1
fi

echo -e "${GREEN}Found $MOD_COUNT mod files${NC}"
echo ""

# List what we're packing
echo -e "${YELLOW}Files to pack:${NC}"
find "$MODS_DIR/g3" -type f | while read -r f; do
    echo "  ${f#$MODS_DIR/}"
done
echo ""

# Check Paks directory exists
if [ ! -d "$PAKS_DIR" ]; then
    echo -e "${RED}ERROR: Paks directory not found at: $PAKS_DIR${NC}"
    echo "Check your GAME_DIR setting in this script."
    exit 1
fi

# Remove old mod pak if it exists
if [ -f "$OUTPUT_PAK" ]; then
    echo -e "${YELLOW}Removing old mod pak...${NC}"
    rm "$OUTPUT_PAK"
fi

# Pack the mod
echo -e "${BLUE}Packing mod...${NC}"
cd "$MODS_DIR"
python3 "$U4PAK" pack --archive-version=3 --mount-point=../../../ "$OUTPUT_PAK" g3/

if [ $? -eq 0 ]; then
    SIZE=$(du -h "$OUTPUT_PAK" | cut -f1)
    
    # Generate .sig file
    OUTPUT_SIG="${OUTPUT_PAK%.pak}.sig"
    SIG_SOURCE=""
    for sigfile in "$PAKS_DIR"/*.sig; do
        if [ -f "$sigfile" ] && [[ "$sigfile" != *"zzz_mods"* ]]; then
            SIG_SOURCE="$sigfile"
            break
        fi
    done

    if [ -n "$SIG_SOURCE" ]; then
        cp "$SIG_SOURCE" "$OUTPUT_SIG"
        echo -e "${GREEN}  Sig copied from: $(basename "$SIG_SOURCE")${NC}"
    else
        touch "$OUTPUT_SIG"
        echo -e "${YELLOW}  No existing .sig found, created empty sig${NC}"
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  SUCCESS! Mod packed ($SIZE)${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  Output: $OUTPUT_PAK"
    echo -e "  Sig:    $OUTPUT_SIG"
    echo ""
    echo -e "  ${YELLOW}Restart the game to load your changes.${NC}"
else
    echo ""
    echo -e "${RED}ERROR: Packing failed!${NC}"
    exit 1
fi
