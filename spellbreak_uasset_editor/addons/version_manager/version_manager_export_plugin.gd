@tool
extends EditorExportPlugin

const GitRepository = preload("res://addons/version_manager/git_repository.gd")


func _get_name() -> String:
	return "VersionManagerRepository"


func _export_begin(
	_features: PackedStringArray,
	_is_debug: bool,
	_path: String,
	_flags: int
) -> void:
	var repository := GitRepository.find_remote(
		ProjectSettings.globalize_path("res://")
	)
	if not bool(repository.success):
		return

	var identifier := GitRepository.github_repository_identifier(
		str(repository.url)
	)
	if identifier.is_empty():
		push_warning(
			"Version Manager could not include update information because the "
			+ "project's Git remote is not a GitHub repository."
		)
		return

	var metadata := JSON.stringify({
		"repository": identifier,
	}).to_utf8_buffer()
	add_file(GitRepository.EXPORT_METADATA_PATH, metadata, false)
