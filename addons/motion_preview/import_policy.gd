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
	if path.get_extension().to_lower() != "fbx":
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
	config.set_value("params", OPTION, true)
	return "changed" if config.save(path + ".import") == OK else "error"


static func collect(directory: EditorFileSystemDirectory, paths: PackedStringArray) -> void:
	for index in directory.get_file_count():
		var path := directory.get_file_path(index)
		if eligible(path):
			paths.append(path)
	for index in directory.get_subdir_count():
		collect(directory.get_subdir(index), paths)
