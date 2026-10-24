@tool
extends RefCounted

const SETTING := "addons/motion_preview/import/auto_import_rest_as_reset"
const OPTION := "animation/import_rest_as_RESET"


static func register_setting() -> void:
	if not ProjectSettings.has_setting(SETTING):
		ProjectSettings.set_setting(SETTING, true)
	ProjectSettings.set_initial_value(SETTING, true)
	ProjectSettings.add_property_info({"name": SETTING, "type": TYPE_BOOL})


static func eligible(path: String) -> bool:
	if path.get_extension().to_lower() != "fbx" or not FileAccess.file_exists(path):
		return false
	var config := ConfigFile.new()
	return config.load(path + ".import") == OK and config.get_value("remap", "importer", "") == "animation_library"


# Returns changed / unchanged / error. Preserve all unrelated import options.
static func enable_reset(path: String) -> String:
	if not eligible(path):
		return "ineligible"
	var config := ConfigFile.new()
	if config.load(path + ".import") != OK:
		return "error"
	if config.get_value("params", OPTION, false):
		return "unchanged"
	if not _remember(path, config):
		return "error"
	config.set_value("params", OPTION, true)
	return "changed" if config.save(path + ".import") == OK else "error"


static func collect(directory: EditorFileSystemDirectory, paths: PackedStringArray) -> void:
	for index in directory.get_file_count():
		var path := directory.get_file_path(index)
		if eligible(path):
			paths.append(path)
	for index in directory.get_subdir_count():
		collect(directory.get_subdir(index), paths)


static func backup_path() -> String:
	# App data can be shared by projects with the same application name.
	var project_id := ProjectSettings.globalize_path("res://").sha256_text().left(16)
	return "user://motion_preview/reset_import_backup_" + project_id + ".cfg"


static func _save_backup(config: ConfigFile) -> bool:
	var path := backup_path()
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		return false
	var temporary := path + ".tmp"
	if config.save(temporary) != OK:
		return false
	return DirAccess.rename_absolute(temporary, path) == OK


static func _remember(path: String, original: ConfigFile) -> bool:
	var backup := ConfigFile.new()
	if FileAccess.file_exists(backup_path()) and backup.load(backup_path()) != OK:
		return false # Never overwrite an unreadable recovery record.
	if backup.has_section_key("original", path):
		var saved: Variant = backup.get_value("original", path)
		return saved is Dictionary and saved.get("present") is bool and saved.get("value") is bool
	backup.set_value("original", path, {"present": original.has_section_key("params", OPTION),
		"value": original.get_value("params", OPTION, false)})
	return _save_backup(backup)


# Restore exactly the option this addon changed; preserve later unrelated edits.
# Keep records for missing or no-longer-eligible files so failures are visible.
static func restore_options() -> Dictionary:
	var backup := ConfigFile.new()
	var paths := PackedStringArray()
	var failures := PackedStringArray()
	if not FileAccess.file_exists(backup_path()):
		return {"paths": paths, "failures": failures}
	if backup.load(backup_path()) != OK:
		failures.append("복원 기록을 읽을 수 없습니다.")
		return {"paths": paths, "failures": failures}
	for path in (backup.get_section_keys("original") if backup.has_section("original") else PackedStringArray()):
		var saved: Variant = backup.get_value("original", path)
		if not eligible(path) or not saved is Dictionary or not saved.get("present") is bool or not saved.get("value") is bool:
			failures.append(path)
			continue
		var config := ConfigFile.new()
		if config.load(path + ".import") != OK:
			failures.append(path)
			continue
		if saved.present:
			config.set_value("params", OPTION, saved.value)
		elif config.has_section_key("params", OPTION):
			config.erase_section_key("params", OPTION)
		if config.save(path + ".import") != OK:
			failures.append(path)
			continue
		paths.append(path)
	return {"paths": paths, "failures": failures}


# Only drop a record after the restored file was reimported successfully.
static func finish_restore(paths: PackedStringArray) -> bool:
	var backup := ConfigFile.new()
	if backup.load(backup_path()) != OK:
		return false
	for path in paths:
		if backup.has_section_key("original", path):
			backup.erase_section_key("original", path)
	return _save_backup(backup)
