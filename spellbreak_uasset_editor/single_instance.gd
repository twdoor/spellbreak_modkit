extends Node
## Manages single/multi instance behavior via a local TCP socket.
##
## Default: files open as new tabs in an existing instance.
## Pass --new-window or -n to force a new instance.
##
## Usage:
##   spellbreak-editor file1.uasset file2.json      → tabs in existing window
##   spellbreak-editor --new-window file.uasset     → new window
##   spellbreak-editor -n file1.uasset file2.json   → new window with both files
##
## Add as autoload. Connect file_received to your tab opener.

signal file_received(path: String)

const PORT := 19473

var _server: TCPServer
var _is_primary: bool = false


func _ready() -> void:
	var args := OS.get_cmdline_args()
	var force_new := _has_flag(args, "--new-window") or _has_flag(args, "-n")
	var files := _collect_files(args)

	# If --new-window: always become a new instance, skip sending
	if not force_new and not files.is_empty():
		if _try_send_to_existing(files):
			get_tree().quit()
			return

	# We're a primary instance — start listening
	_server = TCPServer.new()
	var err := _server.listen(PORT, "127.0.0.1")
	if err != OK:
		# Port taken (another instance exists but we're --new-window)
		# That's fine, we just won't receive from others
		push_warning("SingleInstance: Port %d busy, running without listener" % PORT)
	else:
		_is_primary = true

	# Open files passed on our own command line
	# Deferred so the main scene is fully ready
	if not files.is_empty():
		_open_files_deferred.call_deferred(files)


func _process(_delta: float) -> void:
	if not _is_primary or _server == null:
		return
	if not _server.is_connection_available():
		return

	var peer := _server.take_connection()
	if peer == null:
		return

	peer.set_no_delay(true)
	await get_tree().create_timer(0.05).timeout

	var bytes := peer.get_available_bytes()
	if bytes > 0:
		var data := peer.get_utf8_string(bytes)
		for line in data.split("\n", false):
			var path := line.strip_edges()
			if not path.is_empty():
				file_received.emit(path)

	peer.disconnect_from_host()
	DisplayServer.window_move_to_foreground()


func _try_send_to_existing(files: PackedStringArray) -> bool:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", PORT)

	var waited := 0.0
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and waited < 0.5:
		peer.poll()
		OS.delay_msec(50)
		waited += 0.05

	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false

	# Send all file paths, one per line
	var payload := "\n".join(files)
	peer.put_utf8_string(payload)
	OS.delay_msec(100)
	peer.disconnect_from_host()
	return true


func _open_files_deferred(files: PackedStringArray) -> void:
	for path in files:
		file_received.emit(path)


func _collect_files(args: PackedStringArray) -> PackedStringArray:
	var files := PackedStringArray()
	for arg in args:
		if arg.begins_with("-"):
			continue
		if FileAccess.file_exists(arg) and arg.get_extension().to_lower() in ["json", "uasset"]:
			files.append(arg)
	return files


func _has_flag(args: PackedStringArray, flag: String) -> bool:
	return flag in args


func _exit_tree() -> void:
	if _server != null:
		_server.stop()
