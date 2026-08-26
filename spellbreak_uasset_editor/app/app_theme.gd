class_name AppTheme
## Centralized, runtime-editable theme values for the entire application.
## All semantic color roles, font sizes, and spacing values live here
## so the UI stays consistent and is easy to tweak from one place.
##
## Usage:  label.add_theme_color_override("font_color", AppTheme.TEXT_MUTED)

# ── Background / Panel ────────────────────────────────────────────────────────
static var BG_PRIMARY := Color(0.09, 0.09, 0.09, 1.0)   # main window bg
static var BG_PANEL := Color(0.125, 0.125, 0.125, 1.0) # panels, popups
static var BG_FIELD := Color(0.1, 0.1, 0.1, 0.6)       # input fields
static var BG_HOVER := Color(0.225, 0.225, 0.225, 0.6)  # hovered controls
static var BG_TOAST := Color(0.1, 0.1, 0.1, 0.93)       # toast notification
static var BG_SELECTION := Color(0.15, 0.38, 0.70, 0.55)    # selected row
static var BG_CHROME := Color(0.2, 0.2, 0.2, 1.0)       # bars, popups, dialogs

# ── Accent (from the icon palette) ───────────────────────────────────────────
static var ACCENT := Color(1.0, 0.749, 0.212)         # FFBF36 gold from icon
static var ACCENT_DIM := Color(0.698, 0.737, 0.761)       # B2BCC2 silver from icon

# ── Text colors ──────────────────────────────────────────────────────────────
static var TEXT_PRIMARY := Color(0.875, 0.875, 0.875, 1.0)  # default text
static var TEXT_HEADING := Color(0.9, 0.9, 0.9, 1.0)        # headers / titles
static var TEXT_DIM := Color(0.6, 0.6, 0.6, 1.0)        # field labels, info text
static var TEXT_MUTED := Color(0.5, 0.5, 0.5, 1.0)        # type badges, status, hints
static var TEXT_VERY_MUTED := Color(0.45, 0.45, 0.45, 1.0)    # index numbers
static var TEXT_SUBTLE := Color(0.55, 0.55, 0.55, 1.0)     # key text in text editor
static var TEXT_SECTION := Color(0.7, 0.7, 0.4, 1.0)        # section labels (yellow accent)
static var TEXT_INFO_YELLOW := Color(0.8, 0.8, 0.4, 1.0)      # struct/array child counts
static var TEXT_TOAST := Color(0.92, 0.92, 0.92, 1.0)     # toast message text

# ── Semantic button colors ───────────────────────────────────────────────────
static var BTN_NAV := Color(0.5, 0.7, 1.0, 1.0)        # navigation / link
static var BTN_NAV_HOVER := Color(0.7, 0.85, 1.0, 1.0)
static var BTN_DELETE := Color(0.9, 0.4, 0.4, 1.0)        # delete / danger
static var BTN_DELETE_HOVER := Color(1.0, 0.5, 0.5, 1.0)
static var BTN_ADD := Color(0.4, 0.8, 0.4, 1.0)        # add / success
static var BTN_ADD_HOVER := Color(0.6, 1.0, 0.6, 1.0)
static var BTN_MUTED := Color(0.6, 0.6, 0.6, 1.0)        # secondary actions
static var BTN_MUTED_HOVER := Color(0.9, 0.9, 0.9, 1.0)
static var BTN_PACK := Color(0.952, 0.646, 0.564, 1.0)  # pack action (warm)
static var BTN_LAUNCH := Color(0.9, 0.7, 0.3, 1.0)        # launch action (gold)
static var BTN_NEW_MOD := Color(0.6, 0.85, 0.6, 1.0)       # new mod (green)
static var BTN_REMOVE := Color(0.8, 0.3, 0.3, 1.0)        # remove / warning
static var BTN_SAVE := Color(0.4, 0.85, 0.4, 1.0)       # save button

# ── Reference / import links ────────────────────────────────────────────────
static var REF_COLOR := Color(0.45, 0.65, 0.9, 1.0)      # object reference labels
static var REF_LINE_COLOR := Color(0.5, 0.7, 1.0, 1.0)        # soft-object line edits

# ── Status colors ────────────────────────────────────────────────────────────
static var STATUS_SUCCESS := Color(0.4, 0.8, 0.4, 1.0)
static var STATUS_ERROR := Color(0.8, 0.4, 0.4, 1.0)
static var STATUS_WARNING := Color(0.86, 0.68, 0.32, 1.0)
static var STATUS_ACTIVE := Color(0.3, 0.9, 0.3, 1.0)        # watch-mode active
static var STATUS_IDLE := Color(0.5, 0.5, 0.5, 1.0)
static var STATUS_WORKING := Color(0.698, 0.737, 0.761, 1.0)

enum StatusKind {
	IDLE,
	WORKING,
	WARNING,
	SUCCESS,
	ERROR,
}

# ── Font sizes ───────────────────────────────────────────────────────────────
static var FONT_HEADER := 16
static var FONT_TOAST := 15
static var FONT_REF := 15
static var FONT_DEFAULT := 14  # Godot default
static var FONT_STATUS := 13
static var FONT_SECTION := 12
static var FONT_SMALL := 12
static var FONT_BADGE := 11
static var FONT_STATUS_BAR := 11
static var FONT_TINY := 10

# ── Spacing ──────────────────────────────────────────────────────────────────
static var SPACING_ROW := 8   # horizontal separation inside a property row
static var SPACING_FIELD := 6   # horizontal separation inside compact rows
static var SPACING_TAGS := 3   # vertical separation inside tag lists
static var SPACING_TIGHT := 4   # minimal separation

# ── Margins ──────────────────────────────────────────────────────────────────
static var MARGIN_TOOLBAR_H := 8
static var MARGIN_TOOLBAR_TOP := 6
static var MARGIN_TOOLBAR_BOTTOM := 4
static var MARGIN_STATUS_H := 10
static var MARGIN_STATUS_V := 3
static var MARGIN_LOG_H := 10
static var MARGIN_LOG_TOP := 2
static var MARGIN_LOG_BOTTOM := 6
static var MARGIN_SETTINGS_H := 20
static var MARGIN_SETTINGS_V := 16
static var MARGIN_SELECTABLE_H_L := 6
static var MARGIN_SELECTABLE_H_R := 4
static var MARGIN_SELECTABLE_V := 3

# ── Corner radius ────────────────────────────────────────────────────────────
static var CORNER_RADIUS := 3
static var CORNER_TOAST := 8

# ── Tree ─────────────────────────────────────────────────────────────────────
static var TREE_FONT_COLOR := Color(0.7, 0.7, 0.7, 1.0)
static var TREE_SELECTED := Color(0.234, 0.234, 0.234, 1.0)

# ── Mod tree item colors ────────────────────────────────────────────────────
static var MOD_ENABLED := Color(0.45, 0.9, 0.45, 1.0)     # enabled mod name
static var MOD_DISABLED := Color(0.82, 0.82, 0.82, 1.0)     # disabled mod name
static var MOD_PLACEHOLDER := Color(0.45, 0.45, 0.45, 1.0)     # "no mods found" hint
static var MOD_DIR := Color(0.5, 0.5, 0.58, 1.0)       # directory entries
static var MOD_FILE_UASSET := Color(0.5, 0.75, 1.0, 1.0)       # .uasset file entries
static var MOD_FILE_OTHER := Color(0.62, 0.62, 0.62, 1.0)     # other file entries

# ── Shared theme resource ────────────────────────────────────────────────────
## Preloaded once so every Window can reference it without a separate preload.
static var _theme: Theme = preload("res://app/main_theme.tres")
static var _chrome_background_style: StyleBoxFlat
static var _dialog_styles: Array[WeakRef] = []

# ── Convenience factory methods ──────────────────────────────────────────────

## Explicitly assign the project theme to a Window (ConfirmationDialog, etc.).
## Window nodes don't inherit themes from the scene tree, so this is needed
## for any programmatically created dialog.
static func apply_theme(win: Window) -> void:
	win.theme = _theme
	win.transparent = false
	# Embedded windows otherwise clear their viewport with Godot's default
	# background color, hiding the themed panel placed behind their contents.
	win.transparent_bg = true
	win.extend_to_title = false
	_add_window_background(win)
	win.about_to_popup.connect(_add_window_background.bind(win))
	if win.is_node_ready():
		_add_window_background.call_deferred(win)
	else:
		win.ready.connect(_add_window_background.bind(win), CONNECT_ONE_SHOT)


## Standard file picker setup. Native OS pickers are often application-modal,
## which prevents checking paths or hovering the app while choosing a file.
static func configure_file_dialog(dialog: FileDialog) -> void:
	apply_theme(dialog)
	dialog.use_native_dialog = true
	dialog.exclusive = false
	dialog.transient = false
	dialog.always_on_top = false

## Apply "header" styling to a Label.
static func style_header(label: Label) -> void:
	label.add_theme_font_size_override("font_size", FONT_HEADER)

## Apply "type badge" styling to a Label.
static func style_badge(label: Label) -> void:
	label.add_theme_font_size_override("font_size", FONT_BADGE)
	label.add_theme_color_override("font_color", TEXT_MUTED)

## Apply "section label" styling to a Label.
static func style_section(label: Label) -> void:
	label.add_theme_font_size_override("font_size", FONT_SECTION)
	label.add_theme_color_override("font_color", TEXT_SECTION)

## Apply "info / dim" styling to a Label.
static func style_dim(label: Label) -> void:
	label.add_theme_color_override("font_color", TEXT_DIM)

## Apply "muted" styling to a Label.
static func style_muted(label: Label) -> void:
	label.add_theme_color_override("font_color", TEXT_MUTED)

## Apply "reference" styling to a Label.
static func style_ref(label: Label, size: int = FONT_REF) -> void:
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", REF_COLOR)

## Apply "index" styling to a Label or Button.
static func style_index(ctrl: Control) -> void:
	ctrl.add_theme_color_override("font_color", TEXT_VERY_MUTED)
	if ctrl is Button:
		ctrl.add_theme_color_override("font_hover_color", BTN_NAV_HOVER)

## Apply "nav button" styling to a Button.
static func style_nav_btn(btn: Button) -> void:
	btn.add_theme_color_override("font_color", BTN_NAV)
	btn.add_theme_color_override("font_hover_color", BTN_NAV_HOVER)

## Apply "delete button" styling to a Button.
static func style_delete_btn(btn: Button) -> void:
	btn.add_theme_color_override("font_color", BTN_DELETE)
	btn.add_theme_color_override("font_hover_color", BTN_DELETE_HOVER)

## Apply "add button" styling to a Button.
static func style_add_btn(btn: Button) -> void:
	btn.add_theme_color_override("font_color", BTN_ADD)
	btn.add_theme_color_override("font_hover_color", BTN_ADD_HOVER)

## Apply "muted button" styling to a Button.
static func style_muted_btn(btn: Button) -> void:
	btn.add_theme_color_override("font_color", BTN_MUTED)
	btn.add_theme_color_override("font_hover_color", BTN_MUTED_HOVER)

## Apply status color to a Label.
static func style_status(label: Label, is_error: bool) -> void:
	label.add_theme_color_override("font_color", STATUS_ERROR if is_error else STATUS_IDLE)

static func status_color(kind: int) -> Color:
	match kind:
		StatusKind.WORKING:
			return STATUS_WORKING
		StatusKind.WARNING:
			return STATUS_WARNING
		StatusKind.SUCCESS:
			return STATUS_SUCCESS
		StatusKind.ERROR:
			return STATUS_ERROR
		_:
			return STATUS_IDLE

## Apply semantic status color to a Label.
static func style_status_kind(label: Label, kind: int = StatusKind.IDLE) -> void:
	label.add_theme_color_override("font_color", status_color(kind))

## Create a standard status Label for inline operation feedback.
static func make_status_label(text: String = "", kind: int = StatusKind.IDLE,
		font_size: int = FONT_SMALL) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	label.add_theme_font_size_override("font_size", font_size)
	style_status_kind(label, kind)
	return label

## Update a standard status Label.
static func set_status_label(label: Label, text: String,
		kind: int = StatusKind.IDLE) -> void:
	if not is_instance_valid(label):
		return
	label.text = text
	style_status_kind(label, kind)

## Create a standard toast StyleBoxFlat.
static func make_toast_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = BG_TOAST
	style.corner_radius_top_left = CORNER_TOAST
	style.corner_radius_top_right = CORNER_TOAST
	style.corner_radius_bottom_left = CORNER_TOAST
	style.corner_radius_bottom_right = CORNER_TOAST
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	return style


## Shared application chrome used by bars outside the main content area.
static func make_chrome_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = BG_CHROME
	style.content_margin_left = MARGIN_STATUS_H
	style.content_margin_right = MARGIN_STATUS_H
	style.content_margin_top = MARGIN_STATUS_V
	style.content_margin_bottom = MARGIN_STATUS_V
	return style


## Flat chrome fill without content padding, for tabs and popup backplates.
static func make_chrome_background_style() -> StyleBoxFlat:
	if _chrome_background_style == null:
		_chrome_background_style = StyleBoxFlat.new()
	_chrome_background_style.bg_color = BG_CHROME
	return _chrome_background_style


static func refresh_dynamic_styles() -> void:
	if _chrome_background_style != null:
		_chrome_background_style.bg_color = BG_CHROME
	for index in range(_dialog_styles.size() - 1, -1, -1):
		var style := _dialog_styles[index].get_ref() as StyleBoxFlat
		if style == null:
			_dialog_styles.remove_at(index)
			continue
		style.bg_color = BG_CHROME


static func _add_window_background(win: Window) -> void:
	# AcceptDialog and its subclasses create a private, full-size Panel which is
	# drawn above ordinary Window children. Style it directly; otherwise Godot's
	# default dialog gray hides the chrome background beneath it.
	for child in win.get_children(true):
		var internal_panel := child as Panel
		if internal_panel != null and internal_panel.name != "_AppThemeChromeBackground":
			var dialog_style := StyleBoxFlat.new()
			dialog_style.bg_color = BG_CHROME
			internal_panel.add_theme_stylebox_override("panel", dialog_style)
			_dialog_styles.append(weakref(dialog_style))
	var existing := win.get_node_or_null("_AppThemeChromeBackground") as Panel
	if existing != null:
		existing.add_theme_stylebox_override("panel", make_chrome_background_style())
		return
	var background := Panel.new()
	background.name = "_AppThemeChromeBackground"
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.z_index = -1000
	background.add_theme_stylebox_override("panel", make_chrome_background_style())
	win.add_child(background)
	win.move_child(background, 0)
