#!/usr/bin/env python3
"""
Spellbreak UAsset Tool — Convert between .uasset and .json
Uses UAssetGUI CLI (requires dotnet 8+).

Setup:
  1. Install dotnet:  sudo apt install dotnet-sdk-8.0
     or from: https://dotnet.microsoft.com/download
  2. Run: python3 uasset_tool.py --setup
     (downloads and builds the converter)

Usage:
  python3 uasset_tool.py tojson  <file.uasset>           → creates file.json
  python3 uasset_tool.py fromjson <file.json>             → creates file.uasset + .uexp
  python3 uasset_tool.py export <mod_folder>              → export all uassets to json/
  python3 uasset_tool.py build <mod_folder>               → convert all json/ back to uassets
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
TOOL_DIR = SCRIPT_DIR / "uasset_converter"
PROJECT_FILE = TOOL_DIR / "UAssetConverter.csproj"
TOOL_PUBLISH = TOOL_DIR / "publish"
TOOL_DLL = TOOL_PUBLISH / "UAssetConverter.dll"
ENGINE_VERSION = "VER_UE4_22"  # Spellbreak = UE4.22

C, G, Y, R, D, B, X = "\033[96m","\033[92m","\033[93m","\033[91m","\033[2m","\033[1m","\033[0m"


def check_dotnet():
    try:
        r = subprocess.run(["dotnet", "--version"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            return True, r.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return False, None


def setup():
    """Download and build the UAsset converter tool."""
    print(f"\n{C}{'─'*50}{X}")
    print(f"{C}{B}  UAsset Tool — Setup{X}")
    print(f"{C}{'─'*50}{X}\n")

    # Check dotnet
    ok, ver = check_dotnet()
    if ok:
        print(f"  {G}✓ dotnet {ver}{X}")
    else:
        print(f"  {R}✗ dotnet not found{X}")
        print(f"\n  Install it:")
        print(f"    {B}sudo apt install dotnet-sdk-8.0{X}")
        print(f"    or visit: https://dotnet.microsoft.com/download\n")
        return False

    # Create project
    print(f"  {Y}Creating converter project...{X}")
    TOOL_DIR.mkdir(parents=True, exist_ok=True)

    # Clean old build artifacts
    bin_dir = TOOL_DIR / "bin"
    obj_dir = TOOL_DIR / "obj"
    if bin_dir.exists(): shutil.rmtree(bin_dir)
    if obj_dir.exists(): shutil.rmtree(obj_dir)

    # Clone UAssetAPI from GitHub
    uasset_api_dir = TOOL_DIR / "UAssetAPI"
    if not uasset_api_dir.exists():
        print(f"  {Y}Cloning UAssetAPI from GitHub...{X}")
        r = subprocess.run(
            ["git", "clone", "--depth=1", "https://github.com/atenfyr/UAssetAPI.git",
             str(uasset_api_dir)],
            capture_output=True, text=True, timeout=120,
        )
        if r.returncode != 0:
            print(f"  {R}Git clone failed: {r.stderr.strip()}{X}")
            return False
        print(f"  {G}✓ Cloned UAssetAPI{X}")
    else:
        print(f"  {G}✓ UAssetAPI already cloned{X}")

    api_csproj = uasset_api_dir / "UAssetAPI" / "UAssetAPI.csproj"
    if not api_csproj.exists():
        print(f"  {R}UAssetAPI.csproj not found{X}")
        return False

    # Block Directory.Build.props from the cloned repo leaking into our build
    (TOOL_DIR / "Directory.Build.props").write_text(
        '<Project>\n</Project>\n'
    )
    (TOOL_DIR / "Directory.Build.targets").write_text(
        '<Project>\n</Project>\n'
    )

    # Write .csproj with project reference to just the library
    PROJECT_FILE.write_text(f"""<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="Program.cs" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="{api_csproj}" />
  </ItemGroup>
</Project>
""")

    # Write converter source
    (TOOL_DIR / "Program.cs").write_text(r"""
using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.ExportTypes;

if (args.Length < 2) {
    Console.Error.WriteLine("Usage:");
    Console.Error.WriteLine("  UAssetConverter tojson <file.uasset> [output.json] [engine_version]");
    Console.Error.WriteLine("  UAssetConverter fromjson <file.json> [output.uasset]");
    Console.Error.WriteLine("  UAssetConverter read <file.uasset> [engine_version]   (json to stdout)");
    Console.Error.WriteLine("  UAssetConverter write <file.uasset>                   (json from stdin)");
    Console.Error.WriteLine("  UAssetConverter info <file.uasset> [engine_version]");
    return 1;
}

string cmd = args[0].ToLower();
string input = args[1];

EngineVersion engineVer = EngineVersion.VER_UE4_22;

try {
    switch (cmd) {
        case "tojson": {
            string output = args.Length > 2 ? args[2] : Path.ChangeExtension(input, ".json");
            if (args.Length > 3) Enum.TryParse(args[3], out engineVer);
            var asset = new UAsset(input, engineVer);
            File.WriteAllText(output, asset.SerializeJson());
            Console.WriteLine($"OK: {Path.GetFileName(input)} -> {Path.GetFileName(output)}");
            break;
        }
        case "fromjson": {
            string output = args.Length > 2 ? args[2] : Path.ChangeExtension(input, ".uasset");
            var asset = UAsset.DeserializeJson(File.ReadAllText(input));
            asset.Write(output);
            Console.WriteLine($"OK: {Path.GetFileName(input)} -> {Path.GetFileName(output)}");
            break;
        }
        case "read": {
            if (args.Length > 2) Enum.TryParse(args[2], out engineVer);
            var asset = new UAsset(input, engineVer);
            Console.Write(asset.SerializeJson());
            break;
        }
        case "write": {
            string jsonStr = Console.In.ReadToEnd();
            var asset = UAsset.DeserializeJson(jsonStr);
            asset.Write(input);
            Console.Error.WriteLine($"OK: Written {Path.GetFileName(input)}");
            break;
        }
        case "info": {
            if (args.Length > 2) Enum.TryParse(args[2], out engineVer);
            var asset = new UAsset(input, engineVer);
            Console.WriteLine($"File: {Path.GetFileName(input)}");
            Console.WriteLine($"Exports: {asset.Exports.Count}");
            Console.WriteLine($"Imports: {asset.Imports.Count}");
            Console.WriteLine($"Names: {asset.GetNameMapIndexList().Count}");
            foreach (var exp in asset.Exports) {
                Console.WriteLine($"  Export: {exp.ObjectName} ({exp.GetExportClassType()})");
            }
            break;
        }
        default:
            Console.Error.WriteLine($"Unknown command: {cmd}");
            return 1;
    }
} catch (Exception ex) {
    Console.Error.WriteLine($"Error: {ex.Message}");
    return 1;
}
return 0;
""")

    # Build our converter
    print(f"  {Y}Building converter (this may take a minute)...{X}")
    r = subprocess.run(
        ["dotnet", "publish", str(PROJECT_FILE), "-c", "Release", "-o", str(TOOL_DIR / "publish")],
        capture_output=True, text=True, timeout=180,
    )
    if r.returncode != 0:
        print(f"  {R}Build failed:{X}")
        print(r.stderr[-500:] if r.stderr else r.stdout[-500:])
        return False

    print(f"  {G}✓ Build successful{X}")

    # Test
    print(f"  {Y}Testing...{X}")
    published_dll = TOOL_DIR / "publish" / "UAssetConverter.dll"
    if published_dll.exists():
        print(f"  {G}✓ Converter ready! ({published_dll}){X}")
    else:
        print(f"  {R}✗ Published DLL not found{X}")
        return False

    print(f"\n{G}{'─'*50}{X}")
    print(f"{G}{B}  Setup complete!{X}")
    print(f"{G}{'─'*50}{X}")
    print(f"\n  Convert uasset → json:")
    print(f"    {B}python3 uasset_tool.py tojson path/to/file.uasset{X}")
    print(f"\n  Convert json → uasset:")
    print(f"    {B}python3 uasset_tool.py fromjson path/to/file.json{X}")
    print(f"\n  Export entire mod to json:")
    print(f"    {B}python3 uasset_tool.py export ~/Mods/blitz{X}")
    print(f"\n  Build json back to uassets:")
    print(f"    {B}python3 uasset_tool.py build ~/Mods/blitz{X}\n")
    return True


def run_converter(*args):
    """Run the dotnet converter tool."""
    if not TOOL_DLL.exists():
        print(f"{R}Converter not set up. Run: python3 uasset_tool.py --setup{X}")
        return False, ""

    cmd = ["dotnet", str(TOOL_DLL)] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    output = r.stdout.strip()
    if r.returncode != 0:
        err = r.stderr.strip() or output
        return False, err
    return True, output


def tojson(uasset_path, json_path=None, engine=ENGINE_VERSION):
    """Convert a .uasset to .json"""
    uasset = Path(uasset_path)
    if not uasset.exists():
        return False, f"File not found: {uasset}"
    if json_path is None:
        json_path = uasset.with_suffix(".json")
    return run_converter("tojson", str(uasset), str(json_path), engine)


def fromjson(json_path, uasset_path=None):
    """Convert a .json back to .uasset + .uexp"""
    jp = Path(json_path)
    if not jp.exists():
        return False, f"File not found: {jp}"
    if uasset_path is None:
        uasset_path = jp.with_suffix(".uasset")
    return run_converter("fromjson", str(jp), str(uasset_path))


def info(uasset_path, engine=ENGINE_VERSION):
    """Show info about a .uasset file"""
    return run_converter("info", str(uasset_path), engine)


def read_uasset(uasset_path, engine=ENGINE_VERSION):
    """Read a .uasset and return parsed dict. No files written."""
    if not TOOL_DLL.exists():
        return None, "Converter not set up. Run: python3 uasset_tool.py --setup"
    p = Path(uasset_path)
    if not p.exists():
        return None, f"File not found: {p}"

    cmd = ["dotnet", str(TOOL_DLL), "read", str(p), engine]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        return None, r.stderr.strip() or "read failed"
    try:
        import json
        return json.loads(r.stdout), "OK"
    except Exception as e:
        return None, f"JSON parse error: {e}"


def write_uasset(uasset_path, data):
    """Write a dict back to .uasset. No intermediate files."""
    if not TOOL_DLL.exists():
        return False, "Converter not set up"

    import json
    json_str = json.dumps(data)
    cmd = ["dotnet", str(TOOL_DLL), "write", str(uasset_path)]
    r = subprocess.run(cmd, input=json_str, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        return False, r.stderr.strip() or "write failed"
    return True, r.stderr.strip() or "OK"


def export_mod(mod_folder):
    """Export all .uasset files in a mod folder to .json alongside them."""
    mod = Path(mod_folder)
    g3 = mod / "g3"
    if not g3.exists():
        print(f"{R}No g3/ folder in {mod}{X}")
        return

    uassets = list(g3.rglob("*.uasset"))
    print(f"  {Y}Exporting {len(uassets)} file(s) to JSON...{X}")
    ok_count = 0
    for ua in uassets:
        json_out = ua.with_suffix(".json")
        ok, msg = tojson(ua, json_out)
        if ok:
            ok_count += 1
            print(f"  {G}✓{X} {ua.relative_to(mod)}")
        else:
            print(f"  {R}✗{X} {ua.relative_to(mod)}: {msg}")

    print(f"\n  {G}{ok_count}/{len(uassets)} exported.{X}")
    print(f"  Edit the .json files, then run:")
    print(f"    {B}python3 uasset_tool.py build {mod}{X}")


def build_mod(mod_folder):
    """Convert all .json files back to .uasset in a mod folder."""
    mod = Path(mod_folder)
    g3 = mod / "g3"
    if not g3.exists():
        print(f"{R}No g3/ folder in {mod}{X}")
        return

    jsons = list(g3.rglob("*.json"))
    if not jsons:
        print(f"{Y}No .json files found in {g3}{X}")
        return

    print(f"  {Y}Converting {len(jsons)} JSON file(s) to .uasset...{X}")
    ok_count = 0
    for jp in jsons:
        ua_out = jp.with_suffix(".uasset")
        ok, msg = fromjson(jp, ua_out)
        if ok:
            ok_count += 1
            print(f"  {G}✓{X} {jp.relative_to(mod)}")
        else:
            print(f"  {R}✗{X} {jp.relative_to(mod)}: {msg}")

    print(f"\n  {G}{ok_count}/{len(jsons)} converted.{X}")
    print(f"  Ready to pack!")


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return

    cmd = sys.argv[1]

    if cmd == "--setup":
        setup()
    elif cmd == "tojson":
        if len(sys.argv) < 3:
            print("Usage: uasset_tool.py tojson <file.uasset> [output.json]")
            return
        ok, msg = tojson(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
        print(msg)
    elif cmd == "fromjson":
        if len(sys.argv) < 3:
            print("Usage: uasset_tool.py fromjson <file.json> [output.uasset]")
            return
        ok, msg = fromjson(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
        print(msg)
    elif cmd == "info":
        if len(sys.argv) < 3:
            print("Usage: uasset_tool.py info <file.uasset>")
            return
        ok, msg = info(sys.argv[2])
        print(msg)
    elif cmd == "export":
        if len(sys.argv) < 3:
            print("Usage: uasset_tool.py export <mod_folder>")
            return
        export_mod(sys.argv[2])
    elif cmd == "build":
        if len(sys.argv) < 3:
            print("Usage: uasset_tool.py build <mod_folder>")
            return
        build_mod(sys.argv[2])
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)


if __name__ == "__main__":
    main()
