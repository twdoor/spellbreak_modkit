class_name AppTheme
## Centralized theme constants for the entire application.
## All semantic color roles, font sizes, and spacing values live here
## so the UI stays consistent and is easy to tweak from one place.
##
## Usage:  label.add_theme_color_override("font_color", AppTheme.TEXT_MUTED)

# ── Background / Panel ────────────────────────────────────────────────────────
const BG_PRIMARY     := Color(0.09, 0.09, 0.09, 1.0)   # main window bg
const BG_PANEL       := Color(0.125, 0.125, 0.125, 1.0) # panels, popups
const BG_FIELD       := Color(0.1, 0.1, 0.1, 0.6)       # input fields
const BG_HOVER       := Color(0.225, 0.225, 0.225, 0.6)  # hovered controls
const BG_TOAST       := Color(0.1, 0.1, 0.1, 0.93)       # toast notification
const BG_SELECTION   := Color(0.15, 0.38, 0.70, 0.55)    # selected row

# ── Accent (from the icon palette) ───────────────────────────────────────────
const ACCENT         := Color(1.0, 0.749, 0.212)         # FFBF36 gold from icon
const ACCENT_DIM     := Color(0.698, 0.737, 0.761)       # B2BCC2 silver from icon

# ── Text colors ──────────────────────────────────────────────────────────────
const TEXT_PRIMARY   := Color(0.875, 0.875, 0.875, 1.0)  # default text
const TEXT_HEADING   := Color(0.9, 0.9, 0.9, 1.0)        # headers / titles
const TEXT_DIM       := Color(0.6, 0.6, 0.6, 1.0)        # field labels, info text
const TEXT_MUTED     := Color(0.5, 0.5, 0.5, 1.0)        # type badges, status, hints
const TEXT_VERY_MUTED := Color(0.45, 0.45, 0.45, 1.0)    # index numbers
const TEXT_SUBTLE    := Color(0.55, 0.55, 0.55, 1.0)     # key text in text editor
const TEXT_SECTION   := Color(0.7, 0.7, 0.4, 1.0)        # section labels (yellow accent)
const TEXT_INFO_YELLOW := Color(0.8, 0.8, 0.4, 1.0)      # struct/array child counts
const TEXT_TOAST     := Color(0.92, 0.92, 0.92, 1.0)     # toast message text

# ── Semantic button colors ───────────────────────────────────────────────────
const BTN_NAV        := Color(0.5, 0.7, 1.0, 1.0)        # navigation / link
const BTN_NAV_HOVER  := Color(0.7, 0.85, 1.0, 1.0)
const BTN_DELETE     := Color(0.9, 0.4, 0.4, 1.0)        # delete / danger
const BTN_DELETE_HOVER := Color(1.0, 0.5, 0.5, 1.0)
const BTN_ADD        := Color(0.4, 0.8, 0.4, 1.0)        # add / success
const BTN_ADD_HOVER  := Color(0.6, 1.0, 0.6, 1.0)
const BTN_MUTED      := Color(0.6, 0.6, 0.6, 1.0)        # secondary actions
const BTN_MUTED_HOVER := Color(0.9, 0.9, 0.9, 1.0)
const BTN_PACK       := Color(0.952, 0.646, 0.564, 1.0)  # pack action (warm)
const BTN_LAUNCH     := Color(0.9, 0.7, 0.3, 1.0)        # launch action (gold)
const BTN_NEW_MOD    := Color(0.6, 0.85, 0.6, 1.0)       # new mod (green)
const BTN_REMOVE     := Color(0.8, 0.3, 0.3, 1.0)        # remove / warning
const BTN_SAVE       := Color(0.4, 0.85, 0.4, 1.0)       # save button

# ── Reference / import links ────────────────────────────────────────────────
const REF_COLOR      := Color(0.45, 0.65, 0.9, 1.0)      # object reference labels
const REF_LINE_COLOR := Color(0.5, 0.7, 1.0, 1.0)        # soft-object line edits

# ── Status colors ────────────────────────────────────────────────────────────
const STATUS_SUCCESS := Color(0.4, 0.8, 0.4, 1.0)
const STATUS_ERROR   := Color(0.8, 0.4, 0.4, 1.0)
const STATUS_ACTIVE  := Color(0.3, 0.9, 0.3, 1.0)        # watch-mode active
const STATUS_IDLE    := Color(0.5, 0.5, 0.5, 1.0)

# ── Font sizes ───────────────────────────────────────────────────────────────
const FONT_HEADER    := 16
const FONT_TOAST     := 15
const FONT_REF       := 15
const FONT_DEFAULT   := 14  # Godot default
const FONT_STATUS    := 13
const FONT_SECTION   := 12
const FONT_SMALL     := 12
const FONT_BADGE     := 11
const FONT_STATUS_BAR := 11
const FONT_TINY      := 10

# ── Spacing ──────────────────────────────────────────────────────────────────
const SPACING_ROW    := 8   # horizontal separation inside a property row
const SPACING_FIELD  := 6   # horizontal separation inside compact rows
const SPACING_TAGS   := 3   # vertical separation inside tag lists
const SPACING_TIGHT  := 4   # minimal separation

# ── Margins ──────────────────────────────────────────────────────────────────
const MARGIN_TOOLBAR_H := 8
const MARGIN_TOOLBAR_TOP := 6
const MARGIN_TOOLBAR_BOTTOM := 4
const MARGIN_STATUS_H := 10
const MARGIN_STATUS_V := 3
const MARGIN_LOG_H := 10
const MARGIN_LOG_TOP := 2
const MARGIN_LOG_BOTTOM := 6
const MARGIN_SETTINGS_H := 20
const MARGIN_SETTINGS_V := 16
const MARGIN_SELECTABLE_H_L := 6
const MARGIN_SELECTABLE_H_R := 4
const MARGIN_SELECTABLE_V := 3

# ── Corner radius ────────────────────────────────────────────────────────────
const CORNER_RADIUS  := 3
const CORNER_TOAST   := 8

# ── Tree ─────────────────────────────────────────────────────────────────────
const TREE_FONT_COLOR := Color(0.7, 0.7, 0.7, 1.0)
const TREE_SELECTED   := Color(0.234, 0.234, 0.234, 1.0)

# ── Mod tree item colors ────────────────────────────────────────────────────
const MOD_ENABLED     := Color(0.45, 0.9, 0.45, 1.0)     # enabled mod name
const MOD_DISABLED    := Color(0.82, 0.82, 0.82, 1.0)     # disabled mod name
const MOD_PLACEHOLDER := Color(0.45, 0.45, 0.45, 1.0)     # "no mods found" hint
const MOD_DIR         := Color(0.5, 0.5, 0.58, 1.0)       # directory entries
const MOD_FILE_UASSET := Color(0.5, 0.75, 1.0, 1.0)       # .uasset file entries
const MOD_FILE_OTHER  := Color(0.62, 0.62, 0.62, 1.0)     # other file entries

# ── Shared theme resource ────────────────────────────────────────────────────
## Preloaded once so every Window can reference it without a separate preload.
static var _theme: Theme = preload("res://main_theme.tres")

# ── Convenience factory methods ──────────────────────────────────────────────

## Explicitly assign the project theme to a Window (ConfirmationDialog, etc.).
## Window nodes don't inherit themes from the scene tree, so this is needed
## for any programmatically created dialog.
static func apply_theme(win: Window) -> void:
	win.theme = _theme

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
