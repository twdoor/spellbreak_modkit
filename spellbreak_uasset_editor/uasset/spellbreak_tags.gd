## Thin wrapper kept for backward compatibility.
## All tag data now lives in game_profiles/spellbreak/tags.json and is loaded by GameProfile.
## This file provides a static fallback accessor via the Spellbreak profile.
class_name SpellbreakTags
extends RefCounted

## Lazy-loaded fallback — loads the Spellbreak profile and returns its tags.
static var _cached: Array[String] = []
static var _loaded: bool = false

static var ALL: Array[String]:
	get:
		if not _loaded:
			var p := GameProfile.load_profile("spellbreak")
			_cached = p.tags
			_loaded = true
		return _cached
