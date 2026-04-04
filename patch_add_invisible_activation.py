#!/usr/bin/env python3
"""
Patches a Viscosity-like XGameplayEffect scroll JSON to add the
'Status.Invisible' ActivationRequirements subobject (same as Outbreak).

Usage:
    python3 patch_add_invisible_activation.py <input.json> <output.json>

The input must be a 2-export XGameplayEffect Blueprint (no ActivationRequirements yet).
"""

import json
import sys
import copy

def find_import(imports, object_name):
    for i, imp in enumerate(imports):
        if imp["ObjectName"] == object_name:
            return -(i + 1)
    return None

def patch(data):
    imports = data["Imports"]
    exports = data["Exports"]
    name_map = data.get("NameMap", [])

    assert len(exports) == 2, "Expected exactly 2 exports (class + CDO)"

    # ---- 1. Find existing package imports ----
    g3_idx = find_import(imports, "/Script/g3")
    gameplay_tags_idx = find_import(imports, "/Script/GameplayTags")
    gameolaytag_struct_idx = find_import(imports, "GameplayTag")

    assert g3_idx is not None, "Missing /Script/g3 import"
    assert gameolaytag_struct_idx is not None, "Missing GameplayTag import"

    # ---- 2. Add new imports if not already present ----
    req_class_idx = find_import(imports, "XGameplayEffectTargetTagRequirements")
    if req_class_idx is None:
        imports.append({
            "$type": "UAssetAPI.Import, UAssetAPI",
            "ObjectName": "XGameplayEffectTargetTagRequirements",
            "OuterIndex": g3_idx,
            "ClassPackage": "/Script/CoreUObject",
            "ClassName": "Class",
            "PackageName": None,
            "bImportOptional": False
        })
        req_class_idx = -(len(imports))
        print(f"  Added import [{req_class_idx}] XGameplayEffectTargetTagRequirements")

    req_default_idx = find_import(imports, "Default__XGameplayEffectTargetTagRequirements")
    if req_default_idx is None:
        imports.append({
            "$type": "UAssetAPI.Import, UAssetAPI",
            "ObjectName": "Default__XGameplayEffectTargetTagRequirements",
            "OuterIndex": g3_idx,
            "ClassPackage": "/Script/g3",
            "ClassName": "XGameplayEffectTargetTagRequirements",
            "PackageName": None,
            "bImportOptional": False
        })
        req_default_idx = -(len(imports))
        print(f"  Added import [{req_default_idx}] Default__XGameplayEffectTargetTagRequirements")

    # ---- 3. Build the subobject export ----
    # Export index 3 (1-based). CDO is export[2].
    new_export_idx = 3  # 1-based

    subobject_export = {
        "$type": "UAssetAPI.ExportTypes.NormalExport, UAssetAPI",
        "ObjectName": "XGameplayEffectTargetTagRequirements_0",
        "ObjectFlags": "RF_Public, RF_Transactional, RF_ArchetypeObject",
        "ClassIndex": req_class_idx,
        "SuperIndex": 0,
        "TemplateIndex": req_default_idx,
        "OuterIndex": 2,
        "PackageGuid": "{00000000-0000-0000-0000-000000000000}",
        "ObjectGuid": None,
        "PackageFlags": "PKG_None",
        "bForcedExport": False,
        "bNotForClient": False,
        "bNotForServer": False,
        "bNotAlwaysLoadedForEditorGame": True,
        "bIsAsset": False,
        "bGeneratePublicHash": False,
        "IsInheritedInstance": False,
        "SerialOffset": 0,
        "SerialSize": 0,
        "GeneratePublicHash": False,
        "HasLeadingFourNullBytes": False,
        "SerializationControl": "NoExtension",
        "Operation": "None",
        "Extras": "",
        "ScriptSerializationStartOffset": 0,
        "ScriptSerializationEndOffset": 0,
        # Dependencies
        "CreateBeforeCreateDependencies": [2],
        "CreateBeforeSerializationDependencies": [gameolaytag_struct_idx],
        "SerializationBeforeCreateDependencies": [req_class_idx, req_default_idx],
        "SerializationBeforeSerializationDependencies": [2],
        # Property data: RequireTags = ["Status.Invisible"]
        "Data": [
            {
                "$type": "UAssetAPI.PropertyTypes.Structs.StructPropertyData, UAssetAPI",
                "StructType": "GameplayTagContainer",
                "StructGUID": "{00000000-0000-0000-0000-000000000000}",
                "SerializeNone": True,
                "SerializationControl": "NoExtension",
                "Operation": "None",
                "Name": "RequireTags",
                "ArrayIndex": 0,
                "PropertyTagFlags": "None",
                "PropertyTagExtensions": "NoExtension",
                "PropertyTypeName": None,
                "IsZero": False,
                "Value": [
                    {
                        "$type": "UAssetAPI.PropertyTypes.Structs.GameplayTagContainerPropertyData, UAssetAPI",
                        "Name": "RequireTags",
                        "ArrayIndex": 0,
                        "PropertyTagFlags": "None",
                        "PropertyTagExtensions": "NoExtension",
                        "PropertyTypeName": None,
                        "IsZero": False,
                        "Value": ["Status.Invisible"]
                    }
                ]
            }
        ]
    }

    exports.append(subobject_export)
    print(f"  Added export [{new_export_idx}] XGameplayEffectTargetTagRequirements_0")

    # ---- 4. Update CDO (export[1], 0-based) ----
    cdo = exports[1]

    # Add export[3] to CDO's CreateBeforeSerializationDependencies
    cbs = cdo.get("CreateBeforeSerializationDependencies", [])
    if new_export_idx not in cbs:
        cbs.append(new_export_idx)
        cdo["CreateBeforeSerializationDependencies"] = cbs
        print(f"  Updated CDO CreateBeforeSerializationDependencies: added {new_export_idx}")

    # Add ActivationRequirements property to CDO Data if not already present
    cdo_data = cdo.get("Data", [])
    has_activation = any(p.get("Name") == "ActivationRequirements" for p in cdo_data)
    if not has_activation:
        activation_prop = {
            "$type": "UAssetAPI.PropertyTypes.Objects.ArrayPropertyData, UAssetAPI",
            "ArrayType": "ObjectProperty",
            "Name": "ActivationRequirements",
            "ArrayIndex": 0,
            "PropertyTagFlags": "None",
            "PropertyTagExtensions": "NoExtension",
            "PropertyTypeName": None,
            "IsZero": False,
            "Value": [
                {
                    "$type": "UAssetAPI.PropertyTypes.Objects.ObjectPropertyData, UAssetAPI",
                    "Name": "0",
                    "ArrayIndex": 0,
                    "PropertyTagFlags": "None",
                    "PropertyTagExtensions": "NoExtension",
                    "PropertyTypeName": None,
                    "IsZero": False,
                    "Value": new_export_idx
                }
            ]
        }
        cdo_data.append(activation_prop)
        cdo["Data"] = cdo_data
        print("  Added ActivationRequirements property to CDO")

    # ---- 5. Update class export (export[0], 0-based) ----
    cls_exp = exports[0]
    sbsd = cls_exp.get("SerializationBeforeSerializationDependencies", [])
    if req_default_idx not in sbsd:
        sbsd.append(req_default_idx)
        cls_exp["SerializationBeforeSerializationDependencies"] = sbsd
        print(f"  Updated class export SerializationBeforeSerializationDependencies: added {req_default_idx}")

    # ---- 6. Add new names to NameMap ----
    new_names = [
        "XGameplayEffectTargetTagRequirements_0",
        "XGameplayEffectTargetTagRequirements",
        "Default__XGameplayEffectTargetTagRequirements",
        "ActivationRequirements",
        "RequireTags",
        "Status.Invisible",
    ]
    added_names = []
    for name in new_names:
        if name not in name_map:
            name_map.append(name)
            added_names.append(name)
    if added_names:
        print(f"  Added to NameMap: {added_names}")

    return data


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]

    with open(input_path) as f:
        data = json.load(f)

    print(f"Patching {input_path}...")
    patch(data)

    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)

    print(f"Written to {output_path}")
