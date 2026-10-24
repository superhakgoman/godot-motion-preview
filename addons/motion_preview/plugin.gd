@tool
extends EditorPlugin

const ImportPolicy = preload("import_policy.gd")
const RestImportPlugin = preload("rest_import_plugin.gd")

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
var rest_import_plugin: EditorScenePostImportPlugin
var _pending_rest_imports := {}
var _rest_job_scheduled := false
var _rest_job_running := false
var _rest_bulk_requested := false
var _rest_starting := true
var _rest_dialog_parent: WeakRef


func _enter_tree() -> void:
	PerformanceLog.register_setting()
	ImportPolicy.register_setting()
	_rest_starting = true
	_finish_rest_startup.call_deferred()
	rest_import_plugin = RestImportPlugin.new()
	add_scene_post_import_plugin(rest_import_plugin)
	log_settings_inspector = preload("log_settings_inspector.gd").new()
	log_settings_inspector.host = self
	add_inspector_plugin(log_settings_inspector)
	preload("humanoid_mapping.gd").reload_rules()
	selected_model = get_editor_interface().get_editor_settings().get_project_metadata(
		META_SECTION, "model", "")
	inspector = Inspector.new()
	inspector.host = self
	add_inspector_plugin(inspector)
	get_editor_interface().get_resource_filesystem().filesystem_changed.connect(_queue_refresh)
	get_editor_interface().get_file_system_dock().selection_changed.connect(_selection_changed)
	get_editor_interface().get_resource_filesystem().resources_reimported.connect(_rest_resources_reimported)
	_queue_refresh()


func _exit_tree() -> void:
	Catalog.clear_preview_scene_cache()
	preload("motion_binding.gd").clear_caches()
	var filesystem := get_editor_interface().get_resource_filesystem()
	if filesystem.resources_reimported.is_connected(_rest_resources_reimported):
		filesystem.resources_reimported.disconnect(_rest_resources_reimported)
	_pending_rest_imports.clear()
	if rest_import_plugin != null:
		remove_scene_post_import_plugin(rest_import_plugin)
	rest_import_plugin = null
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
	Catalog.clear_preview_scene_cache()
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


func _finish_rest_startup() -> void:
	if not is_inside_tree():
		return
	var filesystem := get_editor_interface().get_resource_filesystem()
	if filesystem.is_importing() or filesystem.is_scanning():
		get_tree().create_timer(0.1).timeout.connect(_finish_rest_startup)
		return
	_rest_starting = false


func _rest_resources_reimported(paths: PackedStringArray) -> void:
	if _rest_starting or _rest_job_running or not ProjectSettings.get_setting(ImportPolicy.SETTING, true):
		return
	for path in paths:
		if ImportPolicy.eligible(path) and not _pending_rest_imports.has(path):
			_pending_rest_imports[path] = false
	_schedule_rest_job()


func _schedule_rest_job() -> void:
	if _rest_job_scheduled or _pending_rest_imports.is_empty():
		return
	_rest_job_scheduled = true
	get_tree().create_timer(0.1).timeout.connect(_run_rest_job)


func apply_reset_to_existing(dialog_parent: Node = null) -> void:
	if _rest_job_running:
		return
	_rest_dialog_parent = weakref(dialog_parent) if is_instance_valid(dialog_parent) else null
	var paths := PackedStringArray()
	ImportPolicy.collect(get_editor_interface().get_resource_filesystem().get_filesystem(), paths)
	if paths.is_empty():
		_rest_result_dialog("대상 FBX AnimationLibrary가 없습니다.")
		return
	for path in paths:
		_pending_rest_imports[path] = true
	_rest_bulk_requested = true
	_schedule_rest_job()


func _run_rest_job() -> void:
	_rest_job_scheduled = false
	if not is_inside_tree():
		return
	var filesystem := get_editor_interface().get_resource_filesystem()
	if filesystem.is_importing() or filesystem.is_scanning():
		_schedule_rest_job()
		return
	var pending := _pending_rest_imports.duplicate()
	_pending_rest_imports.clear()
	var bulk := _rest_bulk_requested
	_rest_bulk_requested = false
	var paths := PackedStringArray()
	var failed := PackedStringArray()
	for path in pending:
		if not pending[path] and not ProjectSettings.get_setting(ImportPolicy.SETTING, true):
			continue
		var result := ImportPolicy.enable_reset(path)
		if result == "changed" or (result == "unchanged" and pending[path]):
			paths.append(path)
		elif result == "error":
			failed.append(path)
	var succeeded := 0
	_rest_job_running = true
	if not paths.is_empty():
		filesystem.reimport_files(paths)
		for path in paths:
			var library := ResourceLoader.load(path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE) as AnimationLibrary
			var reason := ""
			if library == null:
				reason = "AnimationLibrary를 읽지 못했습니다."
			elif not library.has_animation(&"RESET"):
				reason = "임포트 결과에 RESET이 없습니다."
			elif not library.get_animation(&"RESET").has_meta(preload("rest_pose.gd").META):
				reason = "RESET의 단일 기준 골격을 보존하지 못했습니다. 모션 전용 FBX라면 Import As Skeleton Bones 설정을 확인해 주세요."
			if not reason.is_empty():
				failed.append(path)
				PerformanceLog.diagnostic("reset_import_failed", {"source": path, "reason": reason})
				push_warning("Motion Preview: " + reason + " " + path)
			else:
				succeeded += 1
	_rest_job_running = false
	PerformanceLog.write("RESET import policy: %d reimports | %d failures" % [paths.size(), failed.size()])
	for path in failed:
		push_warning("Motion Preview: RESET 적용 실패: " + path)
	if bulk and is_inside_tree():
		_rest_result_dialog("FBX 재임포트 성공 %d개, 실패 %d개.\n%s" % [succeeded, failed.size(), "\n".join(failed.slice(0, 8))])


func restore_reset_imports(dialog_parent: Node = null) -> void:
	if _rest_job_running:
		return
	_rest_dialog_parent = weakref(dialog_parent) if is_instance_valid(dialog_parent) else null
	var filesystem := get_editor_interface().get_resource_filesystem()
	if filesystem.is_importing() or filesystem.is_scanning():
		_rest_result_dialog("임포트가 끝난 후 복원을 실행해 주세요.")
		return
	# Disable enforcement first, or restoration would immediately be undone.
	var enabled: bool = ProjectSettings.get_setting(ImportPolicy.SETTING, true)
	ProjectSettings.set_setting(ImportPolicy.SETTING, false)
	if ProjectSettings.save() != OK:
		ProjectSettings.set_setting(ImportPolicy.SETTING, enabled)
		_rest_result_dialog("자동 적용 옵션을 저장하지 못해 복원을 중단했습니다.")
		return
	_pending_rest_imports.clear()
	_rest_bulk_requested = false
	var result := ImportPolicy.restore_options()
	var restored := PackedStringArray()
	_rest_job_running = true
	if not result.paths.is_empty():
		filesystem.reimport_files(result.paths)
		for path in result.paths:
			var library := ResourceLoader.load(path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
			if library is AnimationLibrary:
				restored.append(path)
			else:
				result.failures.append(path)
	_rest_job_running = false
	if not restored.is_empty() and not ImportPolicy.finish_restore(restored):
		result.failures.append("복원 기록을 갱신하지 못했습니다. 다음 복원 시 같은 항목이 다시 처리될 수 있습니다.")
	PerformanceLog.write("RESET import restore: %d restored | %d failures" % [restored.size(), result.failures.size()])
	_rest_result_dialog("자동 적용을 껐습니다. 임포트 옵션 복원 %d개, 실패 %d개.\n%s" % [restored.size(), result.failures.size(), "\n".join(result.failures.slice(0, 8))])


func _rest_result_dialog(message: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Motion Preview — RESET 적용"
	dialog.dialog_text = message
	var parent: Node = _rest_dialog_parent.get_ref() if _rest_dialog_parent != null else null
	if not is_instance_valid(parent):
		parent = get_editor_interface().get_base_control()
	parent.add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()
