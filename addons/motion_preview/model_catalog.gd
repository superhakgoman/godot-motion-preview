@tool
extends RefCounted

# 노드를 생성하지 않고 임포트된 씬 구조만 읽는다. 게임 스크립트는 실행하지 않는다.
static func inspect_scene(scene: PackedScene) -> Dictionary:
	var info := {"safe": true, "skeletons": 0, "meshes": 0}
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
		for property in state.get_node_property_count(index):
			var property_name := state.get_node_property_name(index, property)
			var value: Variant = state.get_node_property_value(index, property)
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
	return info.safe and info.skeletons == 1 and info.meshes > 0


static func collect(directory: EditorFileSystemDirectory, paths: PackedStringArray) -> void:
	# EditorFileSystem의 색인을 사용하므로 .gdignore·임포트 제외 폴더는 탐색하지 않는다.
	for index in directory.get_file_count():
		if directory.get_file_type(index) != "PackedScene":
			continue
		var path := directory.get_file_path(index)
		var scene := ResourceLoader.load(path) as PackedScene
		if scene != null and is_model(scene):
			paths.append(path)
	for index in directory.get_subdir_count():
		collect(directory.get_subdir(index), paths)
