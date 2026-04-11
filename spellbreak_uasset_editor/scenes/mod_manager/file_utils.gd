class_name FileUtils extends RefCounted

## Pure-static filesystem helpers shared across the mod manager.
## No state, no UI — just file operations.


## Recursively remove a directory and all its contents.
static func remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if not dir:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		var full := path.path_join(entry)
		if dir.current_is_dir() and not entry.begins_with("."):
			remove_dir_recursive(full)
		elif not dir.current_is_dir():
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


## Read bytes from src, create parent dirs for dst, write bytes.
## Returns OK on success or an error code on failure.
static func copy_file(src: String, dst: String) -> Error:
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var data := FileAccess.get_file_as_bytes(src)
	var out := FileAccess.open(dst, FileAccess.WRITE)
	if not out:
		return FileAccess.get_open_error()
	out.store_buffer(data)
	out.close()
	return OK
