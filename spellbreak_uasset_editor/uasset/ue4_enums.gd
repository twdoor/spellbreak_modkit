## Thin wrapper kept for backward compatibility.
## All enum data now lives in game_profiles/ and is loaded by GameProfile.
## This file provides a static fallback using the Spellbreak profile when no
## game profile is available (e.g. assets loaded outside the mod manager).
class_name UE4Enums

## Lazy-loaded fallback profile (Spellbreak, includes both generic + game enums).
static var _fallback: GameProfile = null

static func _get_fallback() -> GameProfile:
	if _fallback == null:
		_fallback = GameProfile.load_profile("spellbreak")
	return _fallback

## Returns the list of known values for an enum type, or [] if unknown.
static func get_values(enum_type: String) -> PackedStringArray:
	return _get_fallback().get_enum_values(enum_type)

## Returns true if we have any values registered for this enum type.
static func has_enum(enum_type: String) -> bool:
	return _get_fallback().has_enum(enum_type)
