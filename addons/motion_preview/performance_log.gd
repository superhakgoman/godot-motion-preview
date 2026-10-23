@tool
extends RefCounted

const SETTING := "addons/motion_preview/developer/save_performance_logs"
const DIRECTORY := "user://motion_preview/logs"
const FILE_NAME := "performance.log"
const MAX_BYTES := 1024 * 1024
const BACKUPS := 3
static var _reported_error := false


static func register_setting() -> void:
	if not ProjectSettings.has_setting(SETTING):
		ProjectSettings.set_setting(SETTING, false)
	ProjectSettings.set_initial_value(SETTING, false)
	ProjectSettings.add_property_info({"name": SETTING, "type": TYPE_BOOL})


static func write(message: String) -> void:
	print("[Motion Preview] ", message)
	if not ProjectSettings.get_setting(SETTING, false):
		return
	var line := "%s | %s\n" % [Time.get_datetime_string_from_system(), message.left(8192).replace("\n", " ").replace("\r", " ")]
	if not _append(line):
		if not _reported_error:
			push_warning("Motion Preview: 성능 로그를 저장할 수 없습니다: " + ProjectSettings.globalize_path(DIRECTORY))
			_reported_error = true


static func _append(line: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(DIRECTORY) != OK:
		return false
	var path := DIRECTORY.path_join(FILE_NAME)
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE_READ)
	if file == null:
		return false
	if file.get_length() + line.to_utf8_buffer().size() > MAX_BYTES:
		file.close()
		for index in range(BACKUPS, 0, -1):
			var destination := path + ".%d" % index
			var source := path if index == 1 else path + ".%d" % (index - 1)
			if FileAccess.file_exists(destination) and DirAccess.remove_absolute(destination) != OK:
				return false
			if FileAccess.file_exists(source) and DirAccess.rename_absolute(source, destination) != OK:
				return false
		file = FileAccess.open(path, FileAccess.WRITE_READ)
		if file == null:
			return false
	file.seek_end()
	file.store_string(line)
	file.flush()
	var success := file.get_error() == OK
	file.close()
	return success
