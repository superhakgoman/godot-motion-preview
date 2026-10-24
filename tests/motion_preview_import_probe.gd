@tool
extends EditorPlugin

const Policy = preload("res://addons/motion_preview/import_policy.gd")
const Binding = preload("res://addons/motion_preview/motion_binding.gd")
const Rest = preload("res://addons/motion_preview/rest_pose.gd")
var failures := 0
var checks := 0
var events := {}

func _enter_tree() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("IMPORT_POLICY ", "PASS " if ok else "FAIL ", message)

func frames(count: int) -> void:
	for index in count: await get_tree().process_frame

func find_host(node: Node) -> Node:
	if node.get_script() != null and node.get_script().resource_path == "res://addons/motion_preview/plugin.gd": return node
	for child in node.get_children():
		var found := find_host(child)
		if found != null: return found
	return null

func option(path: String) -> bool:
	var config := ConfigFile.new()
	config.clear()
	config.load(path + ".import")
	return config.get_value("params", Policy.OPTION, false)

func imported(path: String) -> AnimationLibrary:
	return ResourceLoader.load(path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE) as AnimationLibrary

func scan_copy(name: String) -> void:
	DirAccess.copy_absolute("res://legacy.FBX", "res://" + name + ".FBX")
	var config := ConfigFile.new()
	config.set_value("remap", "importer", "animation_library")
	config.set_value("remap", "type", "AnimationLibrary")
	config.set_value("params", "nodes/import_as_skeleton_bones", true)
	config.set_value("params", Policy.OPTION, false)
	config.set_value("params", "fbx/importer", 0)
	config.save("res://" + name + ".FBX.import")
	get_editor_interface().get_resource_filesystem().scan()
	await frames(60)

func run() -> void:
	await frames(20)
	var host := find_host(get_tree().root)
	check(host != null, "plugin loaded")
	if host == null:
		get_tree().quit(1); return
	var filesystem := get_editor_interface().get_resource_filesystem()
	filesystem.resources_reimported.connect(func(paths: PackedStringArray):
		for path in paths: events[path] = events.get(path, 0) + 1)
	check(ProjectSettings.get_setting(Policy.SETTING, false), "automatic policy defaults true")
	check(not option("res://legacy.FBX") and not imported("res://legacy.FBX").has_animation(&"RESET"), "installation leaves existing imports unchanged")
	var property := preload("res://addons/motion_preview/import_settings_property.gd").new()
	property.host = host
	get_editor_interface().get_base_control().add_child(property)
	property.apply_button.pressed.emit()
	await frames(90)
	check(option("res://legacy.FBX") and imported("res://legacy.FBX").has_animation(&"RESET"), "bulk button updates options and imports real RESET")
	check(not option("res://model.FBX"), "scene imports are excluded")
	var config := ConfigFile.new()
	config.clear()
	config.load("res://legacy.FBX.import")
	check(config.get_value("params", "animation/fps") == 24, "unrelated import options remain unchanged")
	var library := imported("res://legacy.FBX")
	check(library.get_animation(&"RESET").has_meta(Rest.META), "same-import skeleton data saved on RESET")
	var skeleton := Binding.source_scene(library)
	check(skeleton != null and skeleton.get_meta("_motion_preview_rest_mode", "") == "imported_RESET", "preview reads RESET reference without raw FBX/model guessing")
	if skeleton != null: skeleton.free()
	property.queue_free()
	for dialog in get_editor_interface().get_base_control().find_children("*", "AcceptDialog", true, false):
		if dialog.title == "Motion Preview — RESET 적용": dialog.queue_free()
	ProjectSettings.set_setting(Policy.SETTING, false)
	await scan_copy("optout")
	check(not option("res://optout.FBX") and not imported("res://optout.FBX").has_animation(&"RESET"), "opt-out preserves per-file false")
	ProjectSettings.set_setting(Policy.SETTING, true)
	await scan_copy("automatic")
	await frames(90)
	check(option("res://automatic.FBX") and imported("res://automatic.FBX").has_animation(&"RESET"), "new AnimationLibrary FBX automatically enables RESET")
	check(events.get("res://automatic.FBX", 0) <= 2, "automatic reimport does not loop")
	check(not option("res://optout.FBX"), "enabling policy does not bulk-change old files")
	config.clear()
	config.load("res://automatic.FBX.import")
	config.set_value("params", Policy.OPTION, false)
	config.save("res://automatic.FBX.import")
	filesystem.reimport_files(PackedStringArray(["res://automatic.FBX"]))
	await frames(90)
	check(option("res://automatic.FBX"), "enabled policy overrides a later per-file false")
	# Exercise Godot's actual scene retarget stage, not just raw FBX tracks.
	library = imported("res://automatic.FBX")
	skeleton = Binding.source_scene(library)
	var bone_map := BoneMap.new()
	bone_map.profile = SkeletonProfileHumanoid.new()
	var roles := Binding.Mapping.for_skeleton(skeleton)
	for role in roles:
		bone_map.set_skeleton_bone_name(role, roles[role])
	var skeleton_path: String = library.get_animation(&"RESET").get_meta(Rest.META).paths[0]
	skeleton.free()
	config.clear()
	config.load("res://automatic.FBX.import")
	config.set_value("params", "_subresources", {"nodes": {"PATH:" + skeleton_path: {
		"retarget/bone_map": bone_map, "retarget/bone_renamer/rename_bones": true,
		"retarget/rest_fixer/retarget_method": 2, "retarget/rest_fixer/normalize_position_tracks": true}}})
	config.save("res://automatic.FBX.import")
	filesystem.reimport_files(PackedStringArray(["res://automatic.FBX"]))
	await frames(30)
	library = imported("res://automatic.FBX")
	skeleton = Binding.source_scene(library)
	check(skeleton != null and skeleton.find_bone("LeftUpperArm") >= 0 and skeleton.motion_scale > 0, "RESET reference survives Godot bone renaming and normalized retarget import")
	if skeleton != null: skeleton.free()
	var preview := preload("res://addons/motion_preview/preview_control.gd").new()
	preview.library = imported("res://automatic.FBX")
	get_editor_interface().get_base_control().add_child(preview)
	check("RESET" not in preview.get_motions() and not preview.get_motions().is_empty(), "RESET hidden from normal motion menu")
	preview.queue_free()
	ProjectSettings.set_setting(Policy.SETTING, false)
	host.apply_reset_to_existing()
	await frames(90)
	check(option("res://optout.FBX") and imported("res://optout.FBX").has_animation(&"RESET"), "explicit bulk action also works with automatic policy disabled")
	config.clear()
	config.load("res://legacy.FBX.import")
	config.set_value("params", "animation/fps", 55)
	config.save("res://legacy.FBX.import")
	var backup := ConfigFile.new()
	check(backup.load(Policy.backup_path()) == OK and backup.has_section_key("original", "res://legacy.FBX") and not backup.has_section_key("original", "res://original_true.FBX"), "record only addon-changed options, not originally enabled files")
	var restore_property := preload("res://addons/motion_preview/import_settings_property.gd").new()
	restore_property.host = host
	get_editor_interface().get_base_control().add_child(restore_property)
	restore_property.restore_button.pressed.emit()
	await frames(60)
	check(not ProjectSettings.get_setting(Policy.SETTING, true), "restore disables automatic enforcement")
	check(not option("res://legacy.FBX") and not option("res://automatic.FBX") and not option("res://optout.FBX"), "restore button reinstates original false options")
	check(not imported("res://legacy.FBX").has_animation(&"RESET"), "restoration reimports the original library without added RESET")
	check(option("res://original_true.FBX") and imported("res://original_true.FBX").has_animation(&"RESET"), "restore preserves originally enabled RESET")
	config.clear()
	config.load("res://legacy.FBX.import")
	check(config.get_value("params", "animation/fps") == 55, "restore preserves later unrelated option edits")
	backup.clear()
	backup.load(Policy.backup_path())
	check(not backup.has_section("original") or backup.get_section_keys("original").is_empty(), "successful restoration clears recovery entries")
	restore_property.queue_free()
	backup.clear()
	backup.set_value("original", "res://missing.FBX", {"present": true, "value": false})
	Policy._save_backup(backup)
	var failed_restore := Policy.restore_options()
	backup.clear()
	backup.load(Policy.backup_path())
	check(failed_restore.failures.has("res://missing.FBX") and backup.has_section_key("original", "res://missing.FBX"), "failed restoration retains its recovery record")
	Policy.finish_restore(PackedStringArray(["res://missing.FBX"]))
	backup.clear()
	backup.set_value("original", "res://legacy.FBX", {"present": true, "value": "invalid"})
	Policy._save_backup(backup)
	check(Policy.enable_reset("res://legacy.FBX") == "error" and not option("res://legacy.FBX"), "invalid existing recovery data prevents option mutation")
	Policy.finish_restore(PackedStringArray(["res://legacy.FBX"]))
	check(not Policy.eligible(ProjectSettings.globalize_path("res://legacy.FBX")) and not Policy.eligible("res://.security/../legacy.FBX"), "absolute and traversal paths cannot change import options")
	if FileAccess.file_exists("res://.security/linked.FBX.import"):
		check(Policy.enable_reset("res://.security/linked.FBX") == "ineligible" and not option("res://legacy.FBX"), "symlinked import configuration cannot redirect writes")
	if FileAccess.file_exists("res://.security/source.FBX"):
		check(not Policy.eligible("res://.security/source.FBX"), "symlinked source files are not policy targets")
	if FileAccess.file_exists("res://.security/directory/legacy.FBX"):
		check(not Policy.eligible("res://.security/directory/legacy.FBX"), "symlinked ancestor directories are not policy targets")
	print("IMPORT_POLICY_COMPLETE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
