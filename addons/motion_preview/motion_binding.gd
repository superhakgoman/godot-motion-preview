@tool
extends RefCounted


static func skeletons_in(node: Node) -> Array[Skeleton3D]:
	var result: Array[Skeleton3D] = []
	if node is Skeleton3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(skeletons_in(child))
	return result


const Mapping = preload("humanoid_mapping.gd")


# 원본 골격의 기준 자세와 축을 확보해 모션을 보정한다.
# FBXDocument/GLTFDocument로 원본 파일을 메모리에 읽으며 씬의 수명은 PreviewControl이 관리한다.
# 기준 골격을 확보할 수 없는 라이브러리는 bind()에서 이름이 일치하는 본을 직접 재생한다.
static func source_scene(source: AnimationLibrary, model_paths: PackedStringArray = PackedStringArray()) -> Node:
	var path := source.resource_path.get_slice("::", 0)
	var extension := path.get_extension().to_lower()
	if extension not in ["fbx", "glb", "gltf"] or not FileAccess.file_exists(path):
		return null
	var document: GLTFDocument = FBXDocument.new() if extension == "fbx" else GLTFDocument.new()
	var state: GLTFState = FBXState.new() if extension == "fbx" else GLTFState.new()
	var config := ConfigFile.new()
	config.load(path + ".import")
	# 모션 전용 파일의 노드도 에디터 임포트와 같은 방식으로 Skeleton3D 본으로 읽는다.
	state.import_as_skeleton_bones = config.get_value("params", "nodes/import_as_skeleton_bones", false)
	state.create_animations = false
	# 골격 복원에 필요한 본·Skin 데이터만 읽는다.
	if document.append_from_file(path, state, GLTFDocument.IMPORT_FLAG_DISCARD_MESHES_AND_MATERIALS) != OK:
		return null
	var scene: Node
	if document is FBXDocument:
		# FBX는 append_from_file()에서 본을 포함한 노드 트리까지 구성한다.
		# 그 트리의 기준 골격을 미리보기용 메모리 데이터로 사용한다.
		if state.root_nodes.is_empty():
			return null
		scene = state.get_scene_node(state.root_nodes[0])
		if scene != null:
			while scene.get_parent() != null:
				scene = scene.get_parent()
	else:
		# GLTF는 본과 Skin의 기준 자세를 유지한 채 골격 노드 트리를 생성한다.
		for node in state.get_nodes():
			node.mesh = -1
		state.set_meshes([])
		scene = document.generate_scene(state)
	# 메시 없는 모션의 노드 자세는 클립의 시작 자세일 수 있다.
	# 본 이름과 계층이 일치하는 모델의 Skin 기준 골격을 확보해 시작 자세까지 보존한다.
	var skeletons := skeletons_in(scene) if scene != null else []
	var has_bind_pose := false
	for skin in state.get_skins():
		has_bind_pose = has_bind_pose or not skin.inverse_binds.is_empty()
	if skeletons.size() == 1 and not has_bind_pose:
		var reference := _reference_model(source, skeletons[0], model_paths)
		if reference != null:
			scene.free()
			return reference
	return scene


static func _reference_model(source: AnimationLibrary, original: Skeleton3D, model_paths: PackedStringArray) -> Node:
	var bones := PackedStringArray()
	for name in source.get_animation_list():
		var animation := source.get_animation(name)
		for track in animation.get_track_count():
			if _is_bone_track(animation, track):
				var bone := String(animation.track_get_path(track).get_subname(0))
				if bone not in bones:
					bones.append(bone)
	if bones.is_empty():
		return null
	var result: Node
	var reference: Skeleton3D
	for path in model_paths:
		var packed := ResourceLoader.load(path) as PackedScene
		if packed == null or not preload("model_catalog.gd").is_model(packed):
			continue
		var candidate := packed.instantiate()
		var skeleton := skeletons_in(candidate)[0]
		var matches := true
		for bone in bones:
			var index := skeleton.find_bone(bone)
			var original_index := original.find_bone(bone)
			if index < 0 or original_index < 0:
				matches = false
				break
			var parent := original.get_bone_parent(original_index)
			while parent >= 0 and String(original.get_bone_name(parent)) not in bones:
				parent = original.get_bone_parent(parent)
			var actual_parent := skeleton.get_bone_parent(index)
			while actual_parent >= 0 and String(skeleton.get_bone_name(actual_parent)) not in bones:
				actual_parent = skeleton.get_bone_parent(actual_parent)
			var expected_name := original.get_bone_name(parent) if parent >= 0 else &""
			var actual_name := skeleton.get_bone_name(actual_parent) if actual_parent >= 0 else &""
			if expected_name != actual_name:
				matches = false
				break
		if not matches:
			candidate.free()
			continue
		if reference != null:
			# 같은 이름·계층의 후보가 여러 개면 기준 자세까지 일치할 때 하나로 취급한다.
			for bone in bones:
				if not reference.get_bone_global_rest(reference.find_bone(bone)).is_equal_approx(skeleton.get_bone_global_rest(skeleton.find_bone(bone))):
					candidate.free()
					result.free()
					return null
			candidate.free()
		else:
			result = candidate
			reference = skeleton
	return result


# 클립별로 직접 재생/엔진 리타게팅을 선택하고 미리보기 전용 AnimationLibrary를 만든다.
# 적용 가능한 움직임이 남으면 누락 트랙을 생략하고
# 경고하며, 적용할 키가 없거나 대응된 계층이 잘못된 경우에만 오류로 재생을 중단한다.
static func bind(source: AnimationLibrary, skeleton: Skeleton3D, root: Node, source_skeleton: Skeleton3D = null, source_map: BoneMap = null, target_map: BoneMap = null) -> Dictionary:
	var library := AnimationLibrary.new()
	var errors := {}
	var warnings := {}
	var native_clips := {}
	var skipped := 0
	var source_roles := Mapping.for_skeleton(source_skeleton, source_map) if source_skeleton != null else {}
	var target_roles := Mapping.for_skeleton(skeleton, target_map)
	var bridge: Node3D
	for name in source.get_animation_list():
		# 트랙 경로 변경·제거와 반복 설정은 복사본에서만 수행한다.
		var animation := source.get_animation(name).duplicate(true) as Animation
		var missing := PackedStringArray()
		var tracks := 0
		# 부모 관계나 기준 자세가 다르면 리타게팅 경로를 선택한다.
		var needs_retarget := false
		for track in animation.get_track_count():
			if not _is_bone_track(animation, track):
				continue
			var bone := String(animation.track_get_path(track).get_subname(0))
			if skeleton.find_bone(bone) < 0:
				if bone not in missing:
					missing.append(bone)
				if source_skeleton != null and source_skeleton.find_bone(bone) >= 0:
					needs_retarget = true
			elif source_skeleton != null:
				var src := source_skeleton.find_bone(bone)
				if src >= 0:
					var dst := skeleton.find_bone(bone)
					var src_parent := source_skeleton.get_bone_parent(src)
					var dst_parent := skeleton.get_bone_parent(dst)
					var src_parent_name := source_skeleton.get_bone_name(src_parent) if src_parent >= 0 else ""
					var dst_parent_name := skeleton.get_bone_name(dst_parent) if dst_parent >= 0 else ""
					if src_parent_name != dst_parent_name or not source_skeleton.get_bone_rest(src).is_equal_approx(skeleton.get_bone_rest(dst)):
						needs_retarget = true
		if needs_retarget:
			var issue := Mapping.validate(source_skeleton, source_roles)
			if issue.is_empty():
				issue = Mapping.validate(skeleton, target_roles)
			if not issue.is_empty():
				errors[name] = "미리보기 불가: " + issue + ". 고급 임포트 설정에서 SkeletonProfileHumanoid와 BoneMap을 확인해 주세요."
				continue
			if bridge == null:
				bridge = preload("native_retarget.gd").new()
				bridge.name = "MotionRetarget"
				bridge.configure(source_skeleton, skeleton, source_roles, target_roles)
				root.add_child(bridge)
		var unavailable := PackedStringArray()
		# 미리보기용 복사본에는 본의 위치·회전·스케일 트랙을 유지한다.
		for track in range(animation.get_track_count() - 1, -1, -1):
			if not _is_bone_track(animation, track):
				animation.remove_track(track)
				skipped += 1
				continue
			var bone := String(animation.track_get_path(track).get_subname(0))
			var destination := skeleton
			var destination_bone := bone
			if needs_retarget:
				# 기준 골격에서 대응을 확인할 수 없는 트랙은 생략하고 경고 목록에 추가한다.
				if not bridge.source_names.has(bone):
					if bone not in unavailable:
						unavailable.append(bone)
					animation.remove_track(track)
					continue
				# 원본 골격 복사본을 먼저 움직이고 엔진이 대상 복사본으로 보정한다.
				destination = bridge.source
				destination_bone = bridge.source_names[bone]
				var role := ""
				for key in source_roles:
					if source_roles[key] == bone:
						role = key
						break
				if bone not in source_roles.values() or not target_roles.has(role):
					if bone not in unavailable:
						unavailable.append(bone)
			elif skeleton.find_bone(bone) < 0:
				animation.remove_track(track)
				continue
			animation.track_set_path(track, NodePath("%s:%s" % [root.get_path_to(destination), destination_bone]))
			if not needs_retarget or (bone in source_roles.values() and bone not in unavailable):
				tracks += animation.track_get_key_count(track)
		if errors.has(name):
			continue
		if tracks == 0:
			if source_skeleton == null:
				errors[name] = "미리보기 불가: 모션의 원본 골격을 읽지 못했고, 모델과 이름이 같은 본도 없습니다."
			else:
				errors[name] = "미리보기 불가: 모션과 모델 사이에 대응된 본의 움직임이 없습니다."
			continue
		var notes := PackedStringArray()
		if needs_retarget:
			native_clips[name] = true
			notes.append("Godot 리타게팅을 적용했습니다. 골격·체형 차이로 자세나 발 위치가 정확하지 않을 수 있습니다.")
			var gaps := Mapping.missing_body_roles(source_roles, target_roles)
			if not gaps.is_empty():
				notes.append("대응되지 않은 관절이 있습니다 (%s). 해당 부위와 그 아래의 움직임은 정확하지 않을 수 있습니다." % ", ".join(gaps.slice(0, 5)))
			missing = unavailable
		if not missing.is_empty():
			if source_skeleton == null:
				notes.append("원본 기준 자세가 없어 이름이 일치하는 본만 재생합니다.")
			notes.append("%d개 본의 움직임이 생략됩니다 (%s)." % [missing.size(), ", ".join(missing.slice(0, 3))])
		if not notes.is_empty():
			warnings[name] = "경고: " + " ".join(notes)
		animation.loop_mode = Animation.LOOP_LINEAR
		library.add_animation(name, animation)
	return {"library": library, "errors": errors, "warnings": warnings, "skipped": skipped, "bridge": bridge, "native_clips": native_clips}


static func _is_bone_track(animation: Animation, track: int) -> bool:
	return animation.track_get_type(track) in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D] and animation.track_get_path(track).get_subname_count() == 1
