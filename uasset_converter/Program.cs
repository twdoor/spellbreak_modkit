
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
