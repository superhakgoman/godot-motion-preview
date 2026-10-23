@tool
extends EditorProperty

const PerformanceLog = preload("performance_log.gd")
var enabled_toggle: CheckBox
var open_button: Button


func _init() -> void:
	var row := HBoxContainer.new()
	add_child(row)
	enabled_toggle = CheckBox.new()
	enabled_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enabled_toggle.toggled.connect(func(value: bool): emit_changed(get_edited_property(), value))
	row.add_child(enabled_toggle)
	add_focusable(enabled_toggle)
	open_button = Button.new()
	open_button.text = "로그 폴더 열기"
	open_button.tooltip_text = ProjectSettings.globalize_path(PerformanceLog.DIRECTORY)
	open_button.pressed.connect(_open_folder)
	row.add_child(open_button)
	add_focusable(open_button)


func _update_property() -> void:
	enabled_toggle.set_pressed_no_signal(bool(get_edited_object().get(get_edited_property())))


func _set_read_only(value: bool) -> void:
	enabled_toggle.disabled = value


func _open_folder() -> void:
	var error := DirAccess.make_dir_recursive_absolute(PerformanceLog.DIRECTORY)
	if error == OK:
		error = OS.shell_open(ProjectSettings.globalize_path(PerformanceLog.DIRECTORY))
	if error != OK:
		push_warning("Motion Preview: 로그 폴더를 열 수 없습니다 (%s)." % error_string(error))
