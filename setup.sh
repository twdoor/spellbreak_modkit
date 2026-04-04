#!/bin/bash
# ============================================================
#  Spellbreak Modkit - Setup
#  Run this once to set up your modding environment.
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

MODKIT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODS_DIR="$HOME/spellbreak-mods"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Spellbreak Modkit - Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check Python3
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Python 3 is required but not installed.${NC}"
    echo "Install it with: sudo apt install python3"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} Python 3 found"

# Check/download u4pak
if [ ! -f "$MODKIT_DIR/u4pak/u4pak.py" ]; then
    echo -e "${YELLOW}Downloading u4pak...${NC}"
    cd "$MODKIT_DIR"
    git clone https://github.com/panzi/u4pak.git
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to clone u4pak. Check your internet connection.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}[OK]${NC} u4pak ready"

# Create mods directory with example structure
if [ ! -d "$MODS_DIR" ]; then
    echo -e "${YELLOW}Creating mods directory...${NC}"
    mkdir -p "$MODS_DIR/g3/Content/Blueprints"
    mkdir -p "$MODS_DIR/g3/Content/DataTables"
fi
echo -e "${GREEN}[OK]${NC} Mods directory: $MODS_DIR"

# Make pack script executable
chmod +x "$MODKIT_DIR/pack_mod.sh"
chmod +x "$MODKIT_DIR/unpack_base.sh" 2>/dev/null
echo -e "${GREEN}[OK]${NC} Scripts are executable"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  ${YELLOW}Your modding workflow:${NC}"
echo ""
echo -e "  1. Put modified .uasset/.uexp files in:"
echo -e "     ${BLUE}$MODS_DIR/g3/Content/...${NC}"
echo -e "     (mirror the folder structure from the game pak)"
echo ""
echo -e "  2. Run the packer:"
echo -e "     ${BLUE}$MODKIT_DIR/pack_mod.sh${NC}"
echo ""
echo -e "  3. Restart the game. Done!"
echo ""
echo -e "  ${YELLOW}Example:${NC}"
echo -e "  To mod DA_BattleRoyale_Solo, place your files at:"
echo -e "  $MODS_DIR/g3/Content/Blueprints/GameModes/DA_BattleRoyale_Solo.uasset"
echo -e "  $MODS_DIR/g3/Content/Blueprints/GameModes/DA_BattleRoyale_Solo.uexp"
echo ""
