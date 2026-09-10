@tool
extends Control


const OPEN_OPEN: int = 100
const OPEN_QUICK: int = 101
const OPEN_CLEAR: int = 102

const ITEM_SAVE: int = 100
const ITEM_SAVE_AS: int = 101
const ITEM_CLOSE: int = 102
const ITEM_CLOSE_ALL: int = 103
const ITEM_CLOSE_OTHERS: int = 104
const ITEM_COPY_PATH: int = 200
const ITEM_SHOW_IN_FILESYSTEM: int = 201


signal confirmation_closed()


@onready var parse_timer: Timer = $ParseTimer

# Blank slate banner
@onready var blank_slate: CenterContainer = %BlankSlate

# Dialogs
@onready var new_dialog: FileDialog = $NewDialog
@onready var save_dialog: FileDialog = $SaveDialog
@onready var open_dialog: FileDialog = $OpenDialog
@onready var quick_open_dialog: ConfirmationDialog = $QuickOpenDialog
@onready var quick_open_files_list: VBoxContainer = $QuickOpenDialog/QuickOpenFilesList
@onready var errors_dialog: AcceptDialog = $ErrorsDialog
@onready var build_error_dialog: AcceptDialog = $BuildErrorDialog
@onready var close_confirmation_dialog: ConfirmationDialog = $CloseConfirmationDialog
@onready var updated_dialog: AcceptDialog = $UpdatedDialog

# Toolbar
@onready var new_button: Button = %NewButton
@onready var open_button: MenuButton = %OpenButton
@onready var save_all_button: Button = %SaveAllButton
@onready var find_in_files_button: Button = %FindInFilesButton
@onready var file_name_label: Button = %FilenameLabel
@onready var test_button: Button = %TestButton
@onready var test_line_button: Button = %TestLineButton
@onready var search_button: Button = %SearchButton
@onready var insert_button: MenuButton = %InsertButton
@onready var support_button: Button = %SupportButton
@onready var docs_button: Button = %DocsButton
@onready var version_label: Label = %VersionLabel
@onready var update_button: Button = %UpdateButton

@onready var search_and_replace: Control = %SearchAndReplace

# Code editor
@onready var content: HSplitContainer = %Content
@onready var files_list: Control = %FilesList
@onready var files_popup_menu: PopupMenu = %FilesPopupMenu
@onready var cue_list: Control = %CueList
@onready var code_edit: DMCodeEdit = %CodeEdit
@onready var errors_panel: Control = %ErrorsPanel

var proofread_button: Button
var http_request: HTTPRequest
var results_window: Window
var results_text: RichTextLabel

# The currently open file
var current_file_path: String = "":
	set(next_current_file_path):
		current_file_path = next_current_file_path
		files_list.current_file_path = current_file_path
		if current_file_path == "" or not open_buffers.has(current_file_path):
			file_name_label.text = ""
			save_all_button.disabled = true
			test_button.disabled = true
			test_line_button.disabled = true
			search_button.disabled = true
			insert_button.disabled = true
			content.dragger_visibility = SplitContainer.DRAGGER_HIDDEN
			files_list.hide()
			cue_list.hide()
			code_edit.hide()
			errors_panel.hide()
			search_and_replace.hide()
			blank_slate.show()
		else:
			file_name_label.text = current_file_path.get_file()
			test_button.disabled = false
			test_line_button.disabled = false
			search_button.disabled = false
			insert_button.disabled = false
			content.dragger_visibility = SplitContainer.DRAGGER_VISIBLE
			files_list.show()
			cue_list.show()
			code_edit.show()
			blank_slate.hide()

			var cursor: Vector2 = DMSettings.get_caret(current_file_path)
			var scroll_vertical: float = DMSettings.get_scroll(current_file_path)

			code_edit.text = open_buffers[current_file_path].text
			code_edit.clear_undo_history()
			code_edit.set_cursor(cursor)
			code_edit.scroll_vertical = scroll_vertical
			code_edit.grab_focus()

			_on_code_edit_text_changed()

			errors_panel.errors = []
			code_edit.errors = []
			code_edit.runtime_error = null

			if search_and_replace.visible:
				search_and_replace.search()
	get:
		return current_file_path

# A reference to the currently open files and their last saved text
var open_buffers: Dictionary = {}


func _ready() -> void:
	apply_theme()

	# Start with nothing open
	self.current_file_path = ""

	# Set up the update checker
	version_label.text = "v%s" % DMPlugin.get_version()
	update_button.on_before_refresh = func on_before_refresh() -> bool:
		# Save everything
		DMSettings.set_user_value("just_refreshed", {
			current_file_path = current_file_path,
			open_buffers = open_buffers
		})
		return true

	# Did we just load from an addon version refresh?
	var just_refreshed: Variant = DMSettings.get_user_value("just_refreshed", null)
	if just_refreshed != null:
		DMSettings.set_user_value("just_refreshed", null)
		call_deferred("load_from_version_refresh", just_refreshed)

	# Hook up the search toolbar
	search_and_replace.code_edit = code_edit

	# Connect menu buttons
	insert_button.get_popup().id_pressed.connect(_on_insert_button_menu_id_pressed)

	code_edit.main_view = self
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	editor_settings.settings_changed.connect(_on_editor_settings_changed)
	_on_editor_settings_changed()

	ProjectSettings.settings_changed.connect(_on_project_settings_changed)
	_on_project_settings_changed()

	# Reopen any files that were open when Godot was closed
	if editor_settings.get_setting("text_editor/behavior/files/restore_scripts_on_load"):
		var reopen_files: Array = DMSettings.get_user_value("reopen_files", [])
		for reopen_file: String in reopen_files:
			open_file(reopen_file)

		self.current_file_path = DMSettings.get_user_value("most_recent_reopen_file", "")

	save_all_button.disabled = true

	close_confirmation_dialog.ok_button_text = DMConstants.translate(&"confirm_close.save")
	close_confirmation_dialog.add_button(DMConstants.translate(&"confirm_close.discard"), true, "discard")

	errors_dialog.dialog_text = DMConstants.translate(&"errors_in_script")

	# Update the buffer if a file was modified externally (retains undo step)
	DMPlugin.instance.cache_file_content_changed.connect(_on_cache_file_content_changed)

	EditorInterface.get_file_system_dock().files_moved.connect(_on_files_moved)

	code_edit.get_v_scroll_bar().value_changed.connect(_on_code_edit_scroll_changed)

	_setup_proofread_ui()


func _exit_tree() -> void:
	DMSettings.set_user_value("reopen_files", open_buffers.keys())
	DMSettings.set_user_value("most_recent_reopen_file", self.current_file_path)


func _input(event: InputEvent) -> void:
	if not visible: return

	if event is InputEventKey and event.is_pressed():
		var shortcut: String = DMPlugin.get_editor_shortcut(event)
		match shortcut:
			"close_file":
				get_viewport().set_input_as_handled()
				close_file(current_file_path)
			"save":
				get_viewport().set_input_as_handled()
				save_file(current_file_path)
			"find_in_files":
				get_viewport().set_input_as_handled()
				_on_find_in_files_button_pressed()
			"run_test_scene":
				get_viewport().set_input_as_handled()
				_on_test_button_pressed()


func apply_changes() -> void:
	save_files()


# Check if any open files have unsaved changes.
func count_unsaved_files() -> int:
	var count: int = 0
	for buffer: Dictionary in open_buffers.values():
		if buffer.text != buffer.pristine_text:
			count += 1
	return count


# Load back to the previous buffer regardless of if it was actually saved
func load_from_version_refresh(just_refreshed: Dictionary) -> void:
	if just_refreshed.has("current_file_content"):
		# We just loaded from a version before multiple buffers
		var file: FileAccess = FileAccess.open(just_refreshed.current_file_path, FileAccess.READ)
		var file_text: String = file.get_as_text()
		open_buffers[just_refreshed.current_file_path] = {
			pristine_text = file_text,
			text = just_refreshed.current_file_content
		}
	else:
		open_buffers = just_refreshed.open_buffers

	if just_refreshed.current_file_path != "":
		EditorInterface.edit_resource(load(just_refreshed.current_file_path))
	else:
		EditorInterface.set_main_screen_editor("Dialogue")

	updated_dialog.dialog_text = DMConstants.translate(&"update.success").format({ version = update_button.get_version() })
	updated_dialog.popup_centered()


func new_file(path: String, initial_content: String = "") -> void:
	if open_buffers.has(path):
		remove_file_from_open_buffers(path)

	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if initial_content == "":
		file.store_string(DMSettings.get_setting(DMSettings.NEW_FILE_TEMPLATE, ""))
	else:
		file.store_string(initial_content)

	EditorInterface.get_resource_filesystem().scan()


# Open a dialogue resource for editing
func open_resource(resource: DialogueResource) -> void:
	open_file(resource.resource_path)


func open_file(path: String) -> void:
	if not FileAccess.file_exists(path): return

	if not open_buffers.has(path):
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		var text: String = file.get_as_text()

		open_buffers[path] = {
			cursor = Vector2.ZERO,
			text = text,
			pristine_text = text
		}

	DMSettings.add_recent_file(path)
	build_open_menu()

	files_list.files = open_buffers.keys()
	files_list.select_file(path)

	self.current_file_path = path


func quick_open() -> void:
	quick_open_files_list.files = DMCache.get_files()
	quick_open_dialog.popup_centered()
	quick_open_files_list.focus_filter()


func show_file_in_filesystem(path: String) -> void:
	EditorInterface.get_file_system_dock().navigate_to_path(path)


# Save any open files
func save_files() -> void:
	save_all_button.disabled = true

	var saved_files: PackedStringArray = []
	for path: String in open_buffers:
		if open_buffers[path].text != open_buffers[path].pristine_text:
			saved_files.append(path)
		save_file(path, false)

	if saved_files.size() > 0:
		DMCache.mark_files_for_reimport(saved_files)


# Save a file
func save_file(path: String, rescan_file_system: bool = true) -> void:
	var buffer: Dictionary = open_buffers[path]

	files_list.mark_file_as_unsaved(path, false)
	save_all_button.disabled = files_list.unsaved_files.size() == 0

	# Don't bother saving if there is nothing to save
	if buffer.text == buffer.pristine_text:
		return

	buffer.pristine_text = buffer.text

	# Save the current text
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(buffer.text)
	file.close()

	if rescan_file_system:
		EditorInterface.get_resource_filesystem().scan()

	if DMSettings.get_setting(DMSettings.AUTO_GENERATE_IDS_ON_SAVE, false):
		call_deferred(&"_auto_generate_line_ids")


func _auto_generate_line_ids() -> void:
	DMTranslationUtilities.generate_static_line_ids_for_project()


func close_file(path: String) -> void:
	if not path in open_buffers.keys(): return

	var buffer: Dictionary = open_buffers[path]

	if buffer.text == buffer.pristine_text:
		remove_file_from_open_buffers(path)
		await get_tree().process_frame
	else:
		close_confirmation_dialog.dialog_text = DMConstants.translate(&"confirm_close").format({ path = path.get_file() })
		close_confirmation_dialog.popup_centered()
		await confirmation_closed


func remove_file_from_open_buffers(path: String) -> void:
	if not path in open_buffers.keys(): return

	var current_index: int = open_buffers.keys().find(current_file_path)

	open_buffers.erase(path)
	if open_buffers.size() == 0:
		self.current_file_path = ""
	else:
		current_index = clamp(current_index, 0, open_buffers.size() - 1)
		self.current_file_path = open_buffers.keys()[current_index]

	files_list.files = open_buffers.keys()


# Apply theme colors and icons to the UI
func apply_theme() -> void:
	if is_instance_valid(code_edit):
		var theme_values: DMThemeValues = DMThemeValues.get_values_from_editor()

		code_edit.theme_overrides = theme_values

		new_button.icon = get_theme_icon("New", "EditorIcons")
		new_button.tooltip_text = DMConstants.translate(&"start_a_new_file")

		open_button.icon = get_theme_icon("Load", "EditorIcons")
		open_button.tooltip_text = DMConstants.translate(&"open_a_file")

		save_all_button.icon = get_theme_icon("Save", "EditorIcons")
		save_all_button.tooltip_text = DMConstants.translate(&"start_all_files")

		find_in_files_button.icon = get_theme_icon("ViewportZoom", "EditorIcons")
		find_in_files_button.tooltip_text = DMConstants.translate(&"find_in_files")

		test_button.icon = get_theme_icon("DebugNext", "EditorIcons")
		test_button.tooltip_text = DMConstants.translate(&"test_dialogue")

		test_line_button.icon = get_theme_icon("DebugStep", "EditorIcons")
		test_line_button.tooltip_text = DMConstants.translate(&"test_dialogue_from_line")

		search_button.icon = get_theme_icon("Search", "EditorIcons")
		search_button.tooltip_text = DMConstants.translate(&"search_for_text")

		insert_button.icon = get_theme_icon("RichTextEffect", "EditorIcons")
		insert_button.tooltip_text = DMConstants.translate(&"insert")

		support_button.icon = get_theme_icon("Heart", "EditorIcons")
		support_button.tooltip_text = DMConstants.translate(&"show_support")

		docs_button.icon = get_theme_icon("Help", "EditorIcons")
		docs_button.text = DMConstants.translate(&"docs")

		blank_slate.apply_theme()
		update_button.apply_theme()

		# Set up the effect menu
		var popup: PopupMenu = insert_button.get_popup()
		popup.clear()
		popup.add_icon_item(get_theme_icon("RichTextEffect", "EditorIcons"), DMConstants.translate(&"insert.wave_bbcode"), 0)
		popup.add_icon_item(get_theme_icon("RichTextEffect", "EditorIcons"), DMConstants.translate(&"insert.shake_bbcode"), 1)
		popup.add_separator()
		popup.add_icon_item(get_theme_icon("Time", "EditorIcons"), DMConstants.translate(&"insert.typing_pause"), 3)
		popup.add_icon_item(get_theme_icon("ViewportSpeed", "EditorIcons"), DMConstants.translate(&"insert.typing_speed_change"), 4)
		popup.add_icon_item(get_theme_icon("DebugNext", "EditorIcons"), DMConstants.translate(&"insert.auto_advance"), 5)
		popup.add_separator()
		popup.add_icon_item(get_theme_icon("RichTextEffect", "EditorIcons"), DMConstants.translate(&"insert.cue"), 6)
		popup.add_icon_item(get_theme_icon("RichTextEffect", "EditorIcons"), DMConstants.translate(&"insert.dialogue"), 7)
		popup.add_icon_item(get_theme_icon("RichTextEffect", "EditorIcons"), DMConstants.translate(&"insert.response"), 8)
		popup.add_icon_item(get_theme_icon("RichTextEffect", "EditorIcons"), DMConstants.translate(&"insert.random_lines"), 9)
		popup.add_icon_item(get_theme_icon("RichTextEffect", "EditorIcons"), DMConstants.translate(&"insert.random_text"), 10)
		popup.add_separator()
		popup.add_icon_item(get_theme_icon("RichTextEffect", "EditorIcons"), DMConstants.translate(&"insert.jump"), 11)
		popup.add_icon_item(get_theme_icon("RichTextEffect", "EditorIcons"), DMConstants.translate(&"insert.end_dialogue"), 12)
		popup.add_separator()
		popup.add_icon_item(get_theme_icon("Translation", "EditorIcons"), DMConstants.translate(&"generate_line_ids"), 13)

		# Dialog sizes
		new_dialog.min_size = Vector2(600, 500) * theme_values.scale
		save_dialog.min_size = Vector2(600, 500) * theme_values.scale
		open_dialog.min_size = Vector2(600, 500) * theme_values.scale
		quick_open_dialog.min_size = Vector2(400, 600) * theme_values.scale


#region Helpers


# Move the cursor to a given cue in the dialogue editor
func go_to_cue(cue: String, create_if_none: bool = false) -> void:
	code_edit.go_to_cue(cue, create_if_none)
	code_edit.grab_focus()


# Move the cursor to a given line number.
func go_to_line_number(line_number: int) -> void:
	code_edit.go_to_line_number(line_number)
	code_edit.grab_focus()


# Refresh the open menu with the latest files
func build_open_menu() -> void:
	var menu: PopupMenu = open_button.get_popup()
	menu.clear()
	menu.add_icon_item(get_theme_icon("Load", "EditorIcons"), DMConstants.translate(&"open.open"), OPEN_OPEN)
	menu.add_icon_item(get_theme_icon("Load", "EditorIcons"), DMConstants.translate(&"open.quick_open"), OPEN_QUICK)
	menu.add_separator()

	var recent_files: Array = DMSettings.get_recent_files()
	if recent_files.size() == 0:
		menu.add_item(DMConstants.translate(&"open.no_recent_files"))
		menu.set_item_disabled(2, true)
	else:
		for path: String in recent_files:
			if FileAccess.file_exists(path):
				menu.add_item(path)

	menu.add_separator()
	menu.add_item(DMConstants.translate(&"open.clear_recent_files"), OPEN_CLEAR)
	if menu.id_pressed.is_connected(_on_open_menu_id_pressed):
		menu.id_pressed.disconnect(_on_open_menu_id_pressed)
	menu.id_pressed.connect(_on_open_menu_id_pressed)


# Check the current text for errors
func compile() -> void:
	# Skip if nothing to parse
	if current_file_path == "": return

	var result: DMCompilerResult = DMCompiler.compile_string(code_edit.text, current_file_path)
	code_edit.errors = result.errors
	errors_panel.errors = result.errors
	cue_list.cues = code_edit.get_cues(true)


func show_build_error_dialog() -> void:
	build_error_dialog.dialog_text = DMConstants.translate(&"errors_with_build")
	build_error_dialog.popup_centered()


# Add a translation file to the project settings
func add_path_to_project_translations(path: String) -> void:
	var translations: PackedStringArray = ProjectSettings.get_setting("internationalization/locale/translations")
	if not path in translations:
		translations.append(path)
		ProjectSettings.save()


func show_search_form(is_enabled: bool) -> void:
	if code_edit.last_selected_text:
		search_and_replace.input.text = code_edit.last_selected_text

	search_and_replace.visible = is_enabled
	search_button.set_pressed_no_signal(is_enabled)
	search_and_replace.focus_line_edit()


func run_test_scene(from_key: String) -> void:
	DMSettings.set_user_value("run_key", from_key)
	DMSettings.set_user_value("is_running_test_scene", true)
	DMSettings.set_user_value("run_resource_path", current_file_path)
	var test_scene_path: String = DMSettings.get_setting(DMSettings.CUSTOM_TEST_SCENE_PATH, "res://addons/dialogue_manager/test_scene.tscn")
	EditorInterface.play_custom_scene(test_scene_path)


#endregion

#region Signals


func _on_files_moved(old_file: String, new_file_path: String) -> void:
	if open_buffers.has(old_file):
		open_buffers[new_file_path] = open_buffers[old_file]
		open_buffers.erase(old_file)


func _on_cache_file_content_changed(path: String, new_content: String) -> void:
	if open_buffers.has(path):
		var buffer: Dictionary = open_buffers[path]
		if buffer.text == buffer.pristine_text and buffer.text != new_content:
			buffer.text = new_content
			if path == current_file_path:
				code_edit.text = new_content
				cue_list.cues = code_edit.get_cues(true)
		buffer.pristine_text = new_content


func _on_editor_settings_changed() -> void:
	var editor_settings: EditorSettings = EditorInterface.get_editor_settings()
	code_edit.minimap_draw = editor_settings.get_setting("text_editor/appearance/minimap/show_minimap")
	code_edit.minimap_width = editor_settings.get_setting("text_editor/appearance/minimap/minimap_width")
	code_edit.scroll_smooth = editor_settings.get_setting("text_editor/behavior/navigation/smooth_scrolling")


func _on_project_settings_changed() -> void:
	code_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY if DMSettings.get_setting(DMSettings.WRAP_LONG_LINES, false) else TextEdit.LINE_WRAPPING_NONE


func _on_open_menu_id_pressed(id: int) -> void:
	match id:
		OPEN_OPEN:
			open_dialog.popup_centered()
		OPEN_QUICK:
			quick_open()
		OPEN_CLEAR:
			DMSettings.clear_recent_files()
			build_open_menu()
		_:
			var menu: PopupMenu = open_button.get_popup()
			var item: String = menu.get_item_text(menu.get_item_index(id))
			open_file(item)


func _on_files_list_file_selected(file_path: String) -> void:
	self.current_file_path = file_path


func _on_insert_button_menu_id_pressed(id: int) -> void:
	match id:
		0:
			code_edit.insert_bbcode("[wave amp=25 freq=5]", "[/wave]")
		1:
			code_edit.insert_bbcode("[shake rate=20 level=10]", "[/shake]")
		3:
			code_edit.insert_bbcode("[wait=1]")
		4:
			code_edit.insert_bbcode("[speed=0.2]")
		5:
			code_edit.insert_bbcode("[next=auto]")
		6:
			code_edit.insert_text_at_cursor("~ cue")
		7:
			code_edit.insert_text_at_cursor("Nathan: This is Some Dialogue")
		8:
			code_edit.insert_text_at_cursor("Nathan: Choose a Response...\n- Option 1\n\tNathan: You chose option 1\n- Option 2\n\tNathan: You chose option 2")
		9:
			code_edit.insert_text_at_cursor("% Nathan: This is random line 1.\n% Nathan: This is random line 2.\n%1 Nathan: This is weighted random line 3.")
		10:
			code_edit.insert_text_at_cursor("Nathan: [[Hi|Hello|Howdy]]")
		11:
			code_edit.insert_text_at_cursor("=> cue")
		12:
			code_edit.insert_text_at_cursor("=> END")
		13:
			var cursor: Vector2i = code_edit.get_cursor()
			var scroll_vertical: float = code_edit.scroll_vertical
			code_edit.text = DMTranslationUtilities.generate_static_line_ids_for_text(code_edit.text, current_file_path)
			code_edit.set_cursor(cursor)
			_on_code_edit_text_changed()
			code_edit.set_deferred("scroll_vertical", scroll_vertical)


func _on_main_view_theme_changed() -> void:
	apply_theme()


func _on_main_view_visibility_changed() -> void:
	if visible and is_instance_valid(code_edit):
		code_edit.grab_focus()


func _on_new_button_pressed() -> void:
	new_dialog.current_file = "untitled"
	new_dialog.popup_centered()


func _on_new_dialog_confirmed() -> void:
	var path: String = new_dialog.current_path
	if path.get_file() == ".dialogue":
		path = "%s/untitled.dialogue" % path.get_basename()
	new_file(path)
	open_file(path)


func _on_new_dialog_file_selected(path: String) -> void:
	new_file(path)
	open_file(path)


func _on_save_dialog_file_selected(path: String) -> void:
	if path == "": path = "res://untitled.dialogue"

	new_file(path, code_edit.text)
	open_file(path)


func _on_open_button_about_to_popup() -> void:
	build_open_menu()


func _on_open_dialog_file_selected(path: String) -> void:
	open_file(path)


func _on_quick_open_files_list_file_double_clicked(file_path: String) -> void:
	quick_open_dialog.hide()
	open_file(file_path)


func _on_quick_open_dialog_confirmed() -> void:
	if quick_open_files_list.last_selected_file_path:
		open_file(quick_open_files_list.last_selected_file_path)


func _on_save_all_button_pressed() -> void:
	save_files()


func _on_find_in_files_button_pressed() -> void:
	DMPlugin.show_find_in_dialogue()


func _on_code_edit_text_changed() -> void:
	var buffer: Dictionary = open_buffers[current_file_path]
	buffer.text = code_edit.text

	files_list.mark_file_as_unsaved(current_file_path, buffer.text != buffer.pristine_text)
	save_all_button.disabled = open_buffers.values().filter(func(d: Dictionary) -> bool: return d.text != d.pristine_text).size() == 0

	parse_timer.start(1)


func _on_code_edit_scroll_changed(_value: int) -> void:
	DMSettings.set_scroll(current_file_path, code_edit.scroll_vertical)


func _on_code_edit_active_cue_changed(cue: String) -> void:
	cue_list.select_cue(cue)


func _on_code_edit_caret_changed() -> void:
	DMSettings.set_caret(current_file_path, code_edit.get_cursor())


func _on_code_edit_error_clicked(line_number: int) -> void:
	errors_panel.show_error_for_line_number(line_number)


func _on_cue_list_cue_selected(cue: String) -> void:
	go_to_cue(cue)


func _on_parse_timer_timeout() -> void:
	parse_timer.stop()
	compile()


func _on_errors_panel_error_pressed(line_number: int, column_number: int) -> void:
	code_edit.set_caret_line(line_number - 1)
	code_edit.set_caret_column(column_number)
	code_edit.grab_focus()


func _on_search_button_toggled(button_pressed: bool) -> void:
	show_search_form(button_pressed)


func _on_search_and_replace_open_requested() -> void:
	show_search_form(true)


func _on_search_and_replace_close_requested() -> void:
	search_button.set_pressed_no_signal(false)
	search_and_replace.visible = false
	code_edit.grab_focus()


func _on_test_button_pressed() -> void:
	save_file(current_file_path, false)
	DMCache.reimport_files([current_file_path])

	if errors_panel.errors.size() > 0:
		errors_dialog.popup_centered()
		return

	run_test_scene("")


func _on_test_line_button_pressed() -> void:
	save_file(current_file_path)

	if errors_panel.errors.size() > 0:
		errors_dialog.popup_centered()
		return

	# Find next non-empty line
	var line_to_run: int = 0
	for i: int in range(code_edit.get_cursor().y, code_edit.get_line_count()):
		if not code_edit.get_line(i).is_empty():
			line_to_run = i
			break

	run_test_scene(str(line_to_run))


func _on_support_button_pressed() -> void:
	OS.shell_open("https://patreon.com/nathanhoad")


func _on_docs_button_pressed() -> void:
	OS.shell_open("https://github.com/nathanhoad/godot_dialogue_manager")


func _on_files_list_file_popup_menu_requested(at_position: Vector2) -> void:
	files_popup_menu.position = Vector2(get_viewport().position) + files_list.global_position + at_position
	files_popup_menu.popup()


func _on_files_list_file_middle_clicked(path: String) -> void:
	close_file(path)


func _on_files_popup_menu_about_to_popup() -> void:
	files_popup_menu.clear()

	var shortcuts: Dictionary = DMPlugin.get_editor_shortcuts()

	files_popup_menu.add_item(DMConstants.translate(&"buffer.save"), ITEM_SAVE, OS.find_keycode_from_string(shortcuts.get("save")[0].as_text_keycode()))
	files_popup_menu.add_item(DMConstants.translate(&"buffer.save_as"), ITEM_SAVE_AS)
	files_popup_menu.add_item(DMConstants.translate(&"buffer.close"), ITEM_CLOSE, OS.find_keycode_from_string(shortcuts.get("close_file")[0].as_text_keycode()))
	files_popup_menu.add_item(DMConstants.translate(&"buffer.close_all"), ITEM_CLOSE_ALL)
	files_popup_menu.add_item(DMConstants.translate(&"buffer.close_other_files"), ITEM_CLOSE_OTHERS)
	files_popup_menu.add_separator()
	files_popup_menu.add_item(DMConstants.translate(&"buffer.copy_file_path"), ITEM_COPY_PATH)
	files_popup_menu.add_item(DMConstants.translate(&"buffer.show_in_filesystem"), ITEM_SHOW_IN_FILESYSTEM)


func _on_files_popup_menu_id_pressed(id: int) -> void:
	match id:
		ITEM_SAVE:
			save_file(current_file_path)
		ITEM_SAVE_AS:
			save_dialog.popup_centered()
		ITEM_CLOSE:
			close_file(current_file_path)
		ITEM_CLOSE_ALL:
			for path: String in open_buffers.keys():
				close_file(path)
		ITEM_CLOSE_OTHERS:
			var current_current_file_path: String = current_file_path
			for path: String in open_buffers.keys():
				if path != current_current_file_path:
					await close_file(path)

		ITEM_COPY_PATH:
			DisplayServer.clipboard_set(current_file_path)
		ITEM_SHOW_IN_FILESYSTEM:
			show_file_in_filesystem(current_file_path)


func _on_code_edit_external_file_requested(path: String, cue: String) -> void:
	open_file(path)
	if cue != "":
		code_edit.go_to_cue(cue)
	else:
		code_edit.set_caret_line(0)


func _on_close_confirmation_dialog_confirmed() -> void:
	save_file(current_file_path)
	remove_file_from_open_buffers(current_file_path)
	confirmation_closed.emit()


func _on_close_confirmation_dialog_custom_action(action: StringName) -> void:
	if action == "discard":
		remove_file_from_open_buffers(current_file_path)
	close_confirmation_dialog.hide()
	confirmation_closed.emit()


func _on_find_in_files_result_selected(path: String, cursor: Vector2i, length: int) -> void:
	open_file(path)
	code_edit.select(cursor.y, cursor.x, cursor.y, cursor.x + length)
	code_edit.set_line_as_center_visible(cursor.y)


func _on_filename_label_pressed() -> void:
	EditorInterface.get_file_system_dock().navigate_to_path(current_file_path)


func _on_blank_slate_new_button_pressed() -> void:
	new_dialog.current_file = "untitled"
	new_dialog.popup_centered()


func _on_blank_slate_quick_open_button_pressed() -> void:
	quick_open()

#endregion

func _setup_proofread_ui() -> void:
	# 1. Add Proofread button to the top toolbar
	proofread_button = Button.new()
	proofread_button.text = "Proofread"
	proofread_button.tooltip_text = "Check grammar and spelling with LanguageTool"
	proofread_button.pressed.connect(_on_proofread_pressed)

	# Locate top menu/toolbar container (adjust node path if needed for your DM version)
	var toolbar : Control = %Toolbar
	if toolbar:
		toolbar.add_child(proofread_button)

	# 2. Add HTTPRequest node for API calls
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_proofread_response)

	# 3. Create Non-Modal Floating Window
	results_window = Window.new()
	results_window.title = "LanguageTool Proofreading Results"
	results_window.size = Vector2i(550, 500)
	results_window.visible = false
	results_window.transient = true # Stays attached/on top of Godot Editor
	results_window.exclusive = false # NON-MODAL: Allows typing in editor while open!
	results_window.close_requested.connect(
		func()-> void:
			results_window.hide(),
	)

	# Padding container inside window
	var margin_container : MarginContainer= MarginContainer.new()
	margin_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin_container.add_theme_constant_override("margin_left", 12)
	margin_container.add_theme_constant_override("margin_top", 12)
	margin_container.add_theme_constant_override("margin_right", 12)
	margin_container.add_theme_constant_override("margin_bottom", 12)
	results_window.add_child(margin_container)

	# 4. Copy-Pastable RichTextLabel
	results_text = RichTextLabel.new()
	results_text.bbcode_enabled = true
	results_text.selection_enabled = true # Enables text highlighting & Ctrl+C
	results_text.context_menu_enabled = true # Enables right-click "Copy" menu
	results_text.focus_mode = Control.FOCUS_CLICK
	margin_container.add_child(results_text)

	add_child(results_window)


func _on_proofread_pressed() -> void:
	if not code_edit or code_edit.text.strip_edges().is_empty():
		return

	# Extract clean translatable strings using Dialogue Manager's compiler logic
	var clean_text : String = _prepare_text_for_proofreading(code_edit.text)
	if clean_text.strip_edges().is_empty():
		results_text.text = "[color=yellow]No translatable dialogue or response lines found to proofread.[/color]"
		results_window.popup_centered()
		return

	proofread_button.disabled = true
	proofread_button.text = "Checking..."

	# LanguageTool POST parameters
	var body_data :String= "text=" + clean_text.uri_encode() + "&language=fr&level=picky"
	var headers :PackedStringArray= ["Content-Type: application/x-www-form-urlencoded"]

	var err : Error= http_request.request(
		"https://api.languagetool.org/v2/check",
		headers,
		HTTPClient.METHOD_POST,
		body_data,
	)

	if err != OK:
		proofread_button.disabled = false
		proofread_button.text = "Proofread"
		push_error("LanguageTool HTTP request failed to initialize.")


## Prepares file text for proofreading by extracting dialogue/responses and stripping tags.
## Non-dialogue lines are replaced with empty lines so payload line numbers match the editor 1:1.
func _prepare_text_for_proofreading(raw_text: String) -> String:
	var lines: PackedStringArray = raw_text.split("\n")
	var compiled_lines: Dictionary = DMCompiler.compile_string(raw_text, "").lines
	var prepared_lines: PackedStringArray = []

	for i:int in range(lines.size()):
		var line: String = lines[i]
		var l: String = line.strip_edges()

		# Ignore non-dialogue / non-response lines
		if (
			not [DMConstants.TYPE_DIALOGUE, DMConstants.TYPE_RESPONSE].has(
				DMCompiler.get_line_type(l)
			)
			or not compiled_lines.has(str(i))
		):
			prepared_lines.append("")
			continue

		# 1. Strip [ID:...] tag first so its inner colon doesn't break string splitting
		var clean_line :String= _strip_line_id(line)
		var clean_l :String= clean_line.strip_edges()

		# 2. Extract translatable text
		var translatable_text: String = ""
		if clean_l.begins_with("- "):
			# Response line option
			translatable_text = DMCompiler.extract_translatable_string(clean_l)
		else:
			# Dialogue line: split ONLY at the first unescaped colon after character name
			var colon_idx : int = _find_first_unescaped_colon(clean_l)
			if colon_idx != -1:
				translatable_text = clean_l.substr(colon_idx + 1).strip_edges()
			else:
				translatable_text = clean_l

		# 3. Clean out remaining BBCode, variables, and formatting tags
		translatable_text = _strip_dialogue_tags(translatable_text)
		prepared_lines.append(translatable_text)

	return "\n".join(prepared_lines)


## Strips [ID:...] tags from a line
func _strip_line_id(text: String) -> String:
	var id_regex :RegEx= RegEx.create_from_string("\\[ID:[^\\]]+\\]")
	return id_regex.sub(text, "", true)


## Finds the index of the first unescaped colon in a string
func _find_first_unescaped_colon(text: String) -> int:
	for i:int in range(text.length()):
		if text[i] == ":":
			if i == 0 or text[i - 1] != "\\":
				return i
	return -1


## Strips variables {{var}}, BBCode tags, wait/speed tags, and inline conditions
func _strip_dialogue_tags(text: String) -> String:
	var result :String= text

	# Remove Dialogue Manager variables {{var}} or {var}
	var var_regex :RegEx= RegEx.create_from_string("\\{+[^\\}]+\\}+")
	result = var_regex.sub(result, "", true)

	# Remove inline BBCode / speed / wait / pause / condition tags like [wait=1] or [if ...]
	var tag_regex :RegEx= RegEx.create_from_string("\\[[^\\]]+\\]")
	result = tag_regex.sub(result, "", true)

	return result.strip_edges()


func _on_proofread_response(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
) -> void:
	proofread_button.disabled = false
	proofread_button.text = "Proofread"

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		results_text.text = "[color=red]Failed to connect to LanguageTool API (HTTP Status: %d).[/color]" % response_code
		_show_results_window()
		return

	var json :JSON= JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		results_text.text = "[color=red]Failed to parse LanguageTool JSON response.[/color]"
		_show_results_window()
		return

	var response: Dictionary = json.get_data()
	var matches: Array = response.get("matches", [])

	if matches.is_empty():
		results_text.text = "[color=green][b]✓ No grammar or spelling issues found![/b][/color]"
	else:
		var clean_text :String= _prepare_text_for_proofreading(code_edit.text)
		var raw_lines: PackedStringArray = code_edit.text.split("\n")
		var output :String= "[b]Found %d potential issue(s):[/b]\n\n" % matches.size()

		for item:Dictionary in matches:
			var offset: int = item.get("offset", 0)
			var length: int = item.get("length", 0)
			var message: String = item.get("message", "Issue found")

			var line_number :int= clean_text.substr(0, offset).count("\n") + 1
			var match_word :String= clean_text.substr(offset, length)

			var raw_context :String= ""
			if line_number - 1 < raw_lines.size():
				raw_context = raw_lines[line_number - 1].strip_edges()

			var replacements: Array = item.get("replacements", [])
			var suggestions :Array= []
			for r:Dictionary in replacements.slice(0, 3):
				suggestions.append(r.get("value", ""))

			var sug_string :String= ", ".join(suggestions) if not suggestions.is_empty() else "None"

			output += "[b]Line %d:[/b] [color=orange]\"%s\"[/color]\n" % [line_number, match_word]
			output += "• [i]Context:[/i] [color=gray]%s[/color]\n" % raw_context
			output += "• [i]Issue:[/i] %s\n" % message
			output += "• [color=green]Suggestions:[/color] %s\n\n" % sug_string

		results_text.text = output

	_show_results_window()


func _show_results_window() -> void:
	if not results_window.visible:
		results_window.popup_centered()
