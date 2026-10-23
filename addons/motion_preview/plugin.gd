@tool
extends EditorPlugin

const PerformanceLog = preload("performance_log.gd")

const Catalog = preload("model_catalog.gd")
const Inspector = preload("inspector.gd")
const META_SECTION := "motion_preview"

signal models_changed(paths: PackedStringArray)

var model_paths := PackedStringArray()
var selected_model := ""
var inspector
var log_settings_inspector: EditorInspectorPlugin
var refresh_pending := false
var selection_pending := false


func _enter_tree() -> void:
	PerformanceLog.register_setting()
	log_settings_inspector = preload("log_settings_inspector.gd").new()
	add_inspector_plugin(log_settings_inspector)
	preload("humanoid_mapping.gd").reload_rules()
	selected_model = get_editor_interface().get_editor_settings().get_project_metadata(
		META_SECTION, "model", "")
	inspector = Inspector.new()
	inspector.host = self
	add_inspector_plugin(inspector)
	get_editor_interface().get_resource_filesystem().filesystem_changed.connect(_queue_refresh)
	get_editor_interface().get_file_system_dock().selection_changed.connect(_selection_changed)
	_queue_refresh()


func _exit_tree() -> void:
	var filesystem := get_editor_interface().get_resource_filesystem()
	if filesystem.filesystem_changed.is_connected(_queue_refresh):
		filesystem.filesystem_changed.disconnect(_queue_refresh)
	var dock := get_editor_interface().get_file_system_dock()
	if dock.selection_changed.is_connected(_selection_changed):
		dock.selection_changed.disconnect(_selection_changed)
	if inspector != null:
		inspector.clear_previews()
		remove_inspector_plugin(inspector)
	inspector = null
	if log_settings_inspector != null:
		remove_inspector_plugin(log_settings_inspector)
	log_settings_inspector = null


func _selection_changed() -> void:
	# FBX 단일 클릭 시 선택한 라이브러리를 인스펙터 미리보기에 연결한다.
	if not selection_pending:
		selection_pending = true
		_preview_selected_file.call_deferred()


func _preview_selected_file() -> void:
	selection_pending = false
	if not is_inside_tree():
		return
	var paths := get_editor_interface().get_selected_paths()
	if paths.size() != 1:
		return
	if get_editor_interface().get_resource_filesystem().get_file_type(paths[0]) != "AnimationLibrary":
		return
	var resource := ResourceLoader.load(paths[0]) as AnimationLibrary
	if resource != null and get_editor_interface().get_inspector().get_edited_object() != resource:
		get_editor_interface().edit_resource(resource)


func remember_model(path: String) -> void:
	selected_model = path
	get_editor_interface().get_editor_settings().set_project_metadata(META_SECTION, "model", path)


func _queue_refresh() -> void:
	if refresh_pending:
		return
	refresh_pending = true
	refresh_models.call_deferred()


func refresh_models() -> void:
	preload("motion_binding.gd").clear_caches()
	refresh_pending = false
	if not is_inside_tree():
		return
	var started := Time.get_ticks_usec()
	var paths := PackedStringArray()
	Catalog.collect(get_editor_interface().get_resource_filesystem().get_filesystem(), paths)
	PerformanceLog.write("model catalog: %.1f ms | %d models" % [(Time.get_ticks_usec() - started) / 1000.0, paths.size()])
	paths.sort()
	model_paths = paths
	models_changed.emit(model_paths)
