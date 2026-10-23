@tool
extends RefCounted

const PerformanceLog = preload("performance_log.gd")


# Keep one PackedScene alive across inspector destruction. ResourceLoader's cache
# alone does not retain unused resources after the last strong reference is freed.
static var _preview_scene: PackedScene
static var _preview_scene_path := ""


static func clear_preview_scene_cache() -> void:
	_preview_scene = null
	_preview_scene_path = ""


static func accepts_path(path: String) -> bool:
	return path.get_extension().to_lower() in ["fbx", "glb"]


static func load_preview_scene(path: String) -> PackedScene:
	if not accepts_path(path):
		return null
	if _preview_scene != null and _preview_scene_path == path:
		PerformanceLog.write("model scene cache: hit | " + path)
		return _preview_scene
	clear_preview_scene_cache()
	PerformanceLog.write("model scene cache: miss | " + path)
	var packed := ResourceLoader.load(path) as PackedScene
	if packed != null and is_model(packed):
		_preview_scene = packed
		_preview_scene_path = path
	return packed


# SceneState에서 임포트된 씬 구조와 스크립트·골격·메시 정보를 읽어 모델 후보를 판별한다.
static func inspect_scene(scene: PackedScene) -> Dictionary:
	var info := {"safe": true, "skeletons": 0, "meshes": 0, "rig_paths": [], "retarget_paths": [], "profiled_modifiers": []}
	if scene == null:
		info.safe = false
		return info
	_inspect_state(scene.get_state(), info, 0)
	return info


static func _inspect_state(state: SceneState, info: Dictionary, depth: int) -> void:
	if depth > 32:
		info.safe = false
		return
	var base := state.get_base_scene_state()
	if base != null:
		_inspect_state(base, info, depth + 1)
	for index in state.get_node_count():
		if state.get_node_type(index) == &"Skeleton3D":
			info.skeletons += 1
			info.rig_paths.append(String(state.get_node_path(index)).trim_prefix("./"))
		if state.get_node_type(index) == &"RetargetModifier3D":
			info.retarget_paths.append(String(state.get_node_path(index)).trim_prefix("./"))
		for property in state.get_node_property_count(index):
			var property_name := state.get_node_property_name(index, property)
			var value: Variant = state.get_node_property_value(index, property)
			if state.get_node_type(index) == &"RetargetModifier3D" and property_name == &"profile" and value is SkeletonProfile:
				info.profiled_modifiers.append(String(state.get_node_path(index)).trim_prefix("./"))
			if property_name == &"script" and value != null:
				info.safe = false
			if property_name == &"mesh" and value is Mesh and value.get_surface_count() > 0:
				info.meshes += 1
		var instance := state.get_node_instance(index)
		if instance != null:
			_inspect_state(instance.get_state(), info, depth + 1)
		if state.is_node_instance_placeholder(index):
			info.safe = false


static func is_model(scene: PackedScene) -> bool:
	var info := inspect_scene(scene)
	if not info.safe or info.meshes == 0:
		return false
	if info.skeletons == 1:
		return true
	if info.skeletons != 2 or info.retarget_paths.size() != 1:
		return false
	var modifier: String = info.retarget_paths[0]
	if modifier not in info.profiled_modifiers:
		return false
	var driver := _parent_path(modifier)
	for rig in info.rig_paths:
		if _parent_path(rig) == modifier and driver in info.rig_paths:
			return true
	return false


static func collect(directory: EditorFileSystemDirectory, paths: PackedStringArray) -> void:
	# EditorFileSystem의 색인에 등록된 씬에서 모델 후보를 수집한다.
	for index in directory.get_file_count():
		if directory.get_file_type(index) != "PackedScene" or not accepts_path(directory.get_file_path(index)):
			continue
		var path := directory.get_file_path(index)
		var scene := _preview_scene if _preview_scene_path == path else ResourceLoader.load(path) as PackedScene
		if scene != null and is_model(scene):
			paths.append(path)
	for index in directory.get_subdir_count():
		collect(directory.get_subdir(index), paths)


# Only a single skeleton or the imported driver -> modifier -> deform pair is
# accepted. Independent multi-rig scenes remain unsupported.
static func driving_skeleton(root: Node) -> Skeleton3D:
	var rigs := root.find_children("*", "Skeleton3D", true, false)
	if root is Skeleton3D:
		rigs.push_front(root)
	if rigs.size() == 1:
		return rigs[0]
	if rigs.size() != 2:
		return null
	for rig in rigs:
		var modifier := rig.get_parent()
		if modifier is RetargetModifier3D and modifier.get_parent() is Skeleton3D and modifier.get_parent() in rigs and modifier.profile != null:
			return modifier.get_parent()
	return null


static func _parent_path(path: String) -> String:
	var parent := path.get_base_dir()
	return "." if parent.is_empty() else parent
