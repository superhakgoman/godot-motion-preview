extends SceneTree

const Binding = preload("res://addons/motion_preview/motion_binding.gd")
const Mapping = preload("res://addons/motion_preview/humanoid_mapping.gd")
const Bounds = preload("res://addons/motion_preview/preview_bounds.gd")
var failures := 0
var checks := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	print("RETARGET ", "PASS " if ok else "FAIL ", label)
	if not ok:
		failures += 1

func humanoid(prefix: String, scale: float) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	var profile := SkeletonProfileHumanoid.new()
	for index in profile.bone_size:
		skeleton.add_bone(prefix + String(profile.get_bone_name(index)))
	for index in profile.bone_size:
		var parent := profile.find_bone(profile.get_bone_parent(index))
		skeleton.set_bone_parent(index, parent)
		var rest := profile.get_reference_pose(index)
		rest.origin *= scale
		skeleton.set_bone_rest(index, rest)
	skeleton.reset_bone_poses()
	return skeleton

# 제외한 본을 실제 골격에서 빼고, 남은 본의 모델 공간 기준 자세를 유지한다.
func subset(original: Skeleton3D, exclude: PackedStringArray) -> Skeleton3D:
	var result := Skeleton3D.new()
	var indices := {}
	for index in original.get_bone_count():
		var name := original.get_bone_name(index)
		if name not in exclude:
			indices[index] = result.add_bone(name)
	for index in indices:
		var parent := original.get_bone_parent(index)
		while parent >= 0 and not indices.has(parent):
			parent = original.get_bone_parent(parent)
		var rest := original.get_bone_global_rest(index)
		if parent >= 0:
			rest = original.get_bone_global_rest(parent).affine_inverse() * rest
		result.set_bone_parent(indices[index], indices[parent] if parent >= 0 else -1)
		result.set_bone_rest(indices[index], rest)
	result.reset_bone_poses()
	return result

func check_partial_rigs(root: Node3D, original: Skeleton3D, target: Skeleton3D) -> void:
	var omitted := PackedStringArray()
	for index in target.get_bone_count():
		var name := target.get_bone_name(index)
		if name.begins_with("Left") or name.begins_with("RightUpperLeg") or name.begins_with("RightLowerLeg") or name.begins_with("RightFoot") or name.begins_with("RightToes"):
			omitted.append(name)
	var partial := subset(target, omitted)
	root.add_child(partial)
	var motion := library_for(original)
	var result := Binding.bind(motion, partial, root, original)
	check(result.library.has_animation("move") and result.warnings.move.contains("생략"), "외팔·외다리 모델도 생략 경고와 함께 리타게팅")
	if result.bridge != null:
		var player := AnimationPlayer.new()
		root.add_child(player)
		player.root_node = player.get_path_to(root)
		player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		player.add_animation_library("", result.library)
		player.play("move")
		player.advance(0.4)
		result.bridge.update()
		await frames()
		var arm := partial.find_bone("RightUpperArm")
		check(partial.get_bone_pose_rotation(arm).angle_to(partial.get_bone_rest(arm).basis.get_rotation_quaternion()) > 0.1, "남은 팔에 실제 모션 적용")
		player.free()
		result.bridge.free()
	var same := library_for(target)
	result = Binding.bind(same, partial, root)
	check(result.library.has_animation("move") and result.bridge == null and result.warnings.move.contains("이름이 일치"), "원본 기준 자세 없이도 일치하는 나머지 본 재생")
	var missing_joint := subset(target, PackedStringArray(["LeftLowerArm"]))
	root.add_child(missing_joint)
	result = Binding.bind(motion, missing_joint, root, original)
	check(result.library.has_animation("move") and result.warnings.move.contains("LeftLowerArm"), "중간 관절 누락은 재생하면서 정확도 경고")
	if result.bridge != null:
		result.bridge.free()
	var source_partial := subset(original, PackedStringArray(["mixamorig_LeftLowerArm"]))
	result = Binding.bind(library_for(source_partial), target, root, source_partial)
	check(result.library.has_animation("move") and result.warnings.move.contains("LeftLowerArm"), "모션 쪽 중간 관절 누락도 경고")
	if result.bridge != null:
		result.bridge.free()
	var no_common := Skeleton3D.new()
	no_common.add_bone("Tentacle")
	root.add_child(no_common)
	result = Binding.bind(motion, no_common, root, original)
	check(result.errors.has("move") and not result.library.has_animation("move"), "적용할 관절이 없는 조합은 오류")
	var same_source := humanoid("", 1.0)
	var bad_target := humanoid("", 1.0)
	bad_target.set_bone_parent(bad_target.find_bone("LeftHand"), bad_target.find_bone("Hips"))
	root.add_child(bad_target)
	result = Binding.bind(library_for(same_source), bad_target, root, same_source)
	check(result.errors.has("move"), "본 이름과 로컬 기준 자세가 같아도 다른 계층은 검사")
	bad_target.free()
	same_source.free()
	no_common.free()
	source_partial.free()
	missing_joint.free()
	partial.free()

func check_structural_mapping() -> void:
	var model := humanoid("", 1.0)
	var upper := model.find_bone("LeftUpperArm")
	var lower := model.find_bone("LeftLowerArm")
	model.set_bone_name(upper, "joint_a")
	model.set_bone_name(lower, "joint_b")
	var roles := Mapping.for_skeleton(model)
	check(roles.get("LeftUpperArm") == "joint_a" and roles.get("LeftLowerArm") == "joint_b", "관절 양 끝의 계층·위치로 알 수 없는 이름 추론")
	model.set_bone_rest(lower, Transform3D(Basis.IDENTITY, Vector3(0, -2, 0)))
	roles = Mapping.for_skeleton(model)
	check(not roles.has("LeftUpperArm") and not roles.has("LeftLowerArm"), "접히거나 역순인 기준 위치는 추론하지 않음")
	model.free()
	model = humanoid("", 1.0)
	upper = model.find_bone("LeftUpperArm")
	lower = model.find_bone("LeftLowerArm")
	model.set_bone_name(upper, "joint_a")
	model.set_bone_name(lower, "joint_b")
	var helper := model.add_bone("twist_helper")
	model.set_bone_parent(helper, upper)
	model.set_bone_parent(lower, helper)
	roles = Mapping.for_skeleton(model)
	check(not roles.has("LeftUpperArm") and not roles.has("LeftLowerArm"), "보조 본 때문에 대응이 모호하면 추론 생략")
	model.free()
	check(Mapping.rules.aliases.Hips.has("pelvis") and Mapping.role("thigh_r") == "RightUpperLeg", "JSON에서 별칭·좌우 표기 로딩")
	check(Mapping.role("B-hips") == "Hips" and Mapping.role("B-upperArm.R") == "RightUpperArm", "HumanF 접두어·좌우 본 이름 대응")
	check(Mapping.role("B-indexFinger01.R") == "RightIndexProximal" and Mapping.role("B_L_Toe0") == "LeftToes", "손가락·발끝 별칭 대응")
	Mapping.rules.aliases.Hips.append("newpelvis")
	check(Mapping.role("newpelvis") == "Hips", "알고리즘 수정 없이 별칭 데이터 확장")
	Mapping.reload_rules()
	check(Mapping.role("newpelvis").is_empty(), "JSON 재로딩은 메모리 규칙을 다시 읽음")

func check_source_options() -> void:
	var path := "res://output/motion_preview_checks/nodes_fixture.gltf"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"asset": {"version": "2.0"}, "scene": 0,
		"scenes": [{"nodes": [0]}], "nodes": [{"name": "Root", "children": [1]}, {"name": "Hips", "translation": [0, 1, 0]}]}))
	file.close()
	var config := ConfigFile.new()
	var library := AnimationLibrary.new()
	library.take_over_path(path)
	for enabled in [true, false]:
		config.set_value("params", "nodes/import_as_skeleton_bones", enabled)
		config.save(path + ".import")
		var scene := Binding.source_scene(library)
		var count := Binding.skeletons_in(scene).size() if scene != null else -1
		check(count == (1 if enabled else 0), "메시 없는 원본의 노드→본 임포트 설정 반영: " + str(enabled))
		if scene != null:
			scene.free()
	config.set_value("params", "nodes/import_as_skeleton_bones", true)
	config.save(path + ".import")
	var paths := PackedStringArray()
	for height in [2.0, 3.0]:
		var model := Node3D.new()
		model.name = "Reference"
		var skeleton := Skeleton3D.new()
		model.add_child(skeleton)
		skeleton.owner = model
		skeleton.add_bone("Root")
		skeleton.add_bone("Hips")
		skeleton.set_bone_parent(1, 0)
		skeleton.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(0, height, 0)))
		var mesh := MeshInstance3D.new()
		mesh.mesh = BoxMesh.new()
		model.add_child(mesh)
		mesh.owner = model
		var packed := PackedScene.new()
		packed.pack(model)
		var candidate_path := "res://output/motion_preview_checks/reference_%d.tscn" % int(height)
		ResourceSaver.save(packed, candidate_path)
		paths.append(candidate_path)
		model.free()
	var animation := Animation.new()
	var track := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(track, NodePath("Skeleton:Hips"))
	animation.rotation_track_insert_key(track, 0, Quaternion.IDENTITY)
	library.add_animation("move", animation)
	var scene := Binding.source_scene(library, PackedStringArray([paths[0]]))
	var skeleton := Binding.skeletons_in(scene)[0]
	check(is_equal_approx(skeleton.get_bone_global_rest(skeleton.find_bone("Hips")).origin.y, 2.0), "유일한 같은 골격 모델에서 기준 자세 확보")
	scene.free()
	scene = Binding.source_scene(library, paths)
	skeleton = Binding.skeletons_in(scene)[0]
	check(is_equal_approx(skeleton.get_bone_global_rest(skeleton.find_bone("Hips")).origin.y, 1.0), "후보 기준 자세가 다르면 모션 원본 골격 유지")
	scene.free()

func check_skinned_bounds(root: Node3D) -> void:
	var skeleton := Skeleton3D.new()
	skeleton.name = "BoundsSkeleton"
	skeleton.add_bone("Root")
	var rest := Transform3D(Basis(Vector3.RIGHT, -PI / 2), Vector3(0, 2, 0))
	skeleton.set_bone_rest(0, rest)
	skeleton.reset_bone_poses()
	root.add_child(skeleton)
	var box := BoxMesh.new()
	box.size = Vector3(1, 0.5, 3)
	for influences in [4, 8]:
		var arrays := box.get_mesh_arrays()
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		for vertex in vertices.size():
			for influence in influences:
				bones.append(0)
				weights.append(1.0 if influence == 0 else 0.0)
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		var mesh := MeshInstance3D.new()
		mesh.mesh = ArrayMesh.new()
		mesh.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if influences == 8 else 0)
		var skin := Skin.new()
		skin.add_named_bind("Root", Transform3D.IDENTITY)
		mesh.skin = skin
		mesh.skeleton = NodePath("../BoundsSkeleton")
		root.add_child(mesh)
		var actual := Bounds.mesh_bounds(mesh)
		var expected := rest * box.get_aabb()
		check(actual.position.is_equal_approx(expected.position) and actual.size.is_equal_approx(expected.size), "Skin으로 세워진 메시의 현재 범위: %d개 가중치" % influences)
		mesh.free()
	skeleton.free()

func library_for(skeleton: Skeleton3D) -> AnimationLibrary:
	var clip := Animation.new()
	clip.length = 1.0
	for index in skeleton.get_bone_count():
		var track := clip.add_track(Animation.TYPE_ROTATION_3D)
		clip.track_set_path(track, NodePath("Skeleton:" + skeleton.get_bone_name(index)))
		var rest := skeleton.get_bone_rest(index).basis.get_rotation_quaternion()
		# 첫 프레임부터 움직인 자세를 생성해 리타게팅 후 동작 보존을 검사한다.
		clip.rotation_track_insert_key(track, 0.0, rest * Quaternion(Vector3.UP, 0.35))
		clip.rotation_track_insert_key(track, 1.0, rest * Quaternion(Vector3.UP, 0.8))
	var hip := skeleton.find_bone("mixamorig_Hips")
	if hip >= 0:
		var track := clip.add_track(Animation.TYPE_POSITION_3D)
		clip.track_set_path(track, NodePath("Skeleton:mixamorig_Hips"))
		clip.position_track_insert_key(track, 0.0, skeleton.get_bone_rest(hip).origin)
		clip.position_track_insert_key(track, 1.0, skeleton.get_bone_rest(hip).origin + Vector3(0, 0, 0.2))
	var library := AnimationLibrary.new()
	library.add_animation("move", clip)
	return library

func frames() -> void:
	for index in 3:
		await process_frame

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var root := Node3D.new()
	root.process_mode = Node.PROCESS_MODE_DISABLED
	get_root().add_child(root)
	var target := humanoid("", 2.0)
	target.name = "Target"
	root.add_child(target)
	var original := humanoid("mixamorig_", 1.0)
	var mixamo := humanoid("mixamorig_", 1.0)
	mixamo.set_bone_name(mixamo.find_bone("mixamorig_Chest"), "mixamorig_Spine1")
	mixamo.set_bone_name(mixamo.find_bone("mixamorig_UpperChest"), "mixamorig_Spine2")
	var mixamo_roles := Mapping.for_skeleton(mixamo)
	check(mixamo_roles.get("Spine") == "mixamorig_Spine" and mixamo_roles.get("Chest") == "mixamorig_Spine1" and mixamo_roles.get("UpperChest") == "mixamorig_Spine2", "척추 번호 대신 실제 계층 순서로 매핑")
	mixamo.free()
	await check_partial_rigs(root, original, target)
	check_structural_mapping()
	check_source_options()
	check_skinned_bounds(root)
	var motion := library_for(original)
	var roles := Mapping.for_skeleton(original)
	check(Mapping.validate(original, roles).is_empty(), "엔진 프로필의 대응 본과 계층 검사")
	var result := Binding.bind(motion, target, root, original)
	check(result.library.has_animation("move") and result.native_clips.has("move"), "다른 이름의 인간형 골격은 엔진 리타게팅")
	if result.bridge == null:
		check(false, "엔진 리타게팅 생성")
		root.free()
		original.free()
		quit(1)
		return
	var bridge: Node = result.bridge
	check(bridge.modifier is RetargetModifier3D and bridge.modifier.profile is SkeletonProfileHumanoid, "Godot 기본 RetargetModifier3D 사용")
	check(not bridge.modifier.use_global_pose, "체형 차이를 보존하는 로컬 보정")
	var player := AnimationPlayer.new()
	player.deterministic = true
	root.add_child(player)
	player.root_node = player.get_path_to(root)
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	player.add_animation_library("", result.library)
	player.play("move")
	player.advance(0.0)
	bridge.update()
	await frames()
	var arm := target.find_bone("LeftUpperArm")
	var first := target.get_bone_pose_rotation(arm)
	check(first.angle_to(target.get_bone_rest(arm).basis.get_rotation_quaternion()) > 0.1, "첫 프레임의 실제 자세를 보존")
	player.seek(0.5, true)
	bridge.update()
	await frames()
	check(target.get_bone_pose_rotation(arm).angle_to(first) > 0.1, "시간 이동으로 대상 본이 움직임")
	var hip := target.find_bone("Hips")
	check(is_equal_approx(target.get_bone_pose_position(hip).z - target.get_bone_rest(hip).origin.z, 0.2), "골반 이동량은 체형 비율에 맞춰 엔진이 보정")
	check(target.get_bone_name(arm) == "LeftUpperArm" and original.get_bone_name(arm) == "mixamorig_LeftUpperArm", "실제 모델과 원본 본 이름 보존")
	check(motion.get_animation("move").loop_mode == Animation.LOOP_NONE and motion.get_animation("move").track_get_path(0) == NodePath("Skeleton:mixamorig_Root"), "원본 모션 트랙과 반복 설정 보존")
	bridge.free()
	result = Binding.bind(motion, target, root)
	check(result.errors.has("move") and not result.library.has_animation("move"), "기준 자세가 없으면 첫 프레임 보정을 하지 않음")
	var same := library_for(target)
	var missing := same.get_animation("move").add_track(Animation.TYPE_ROTATION_3D)
	same.get_animation("move").track_set_path(missing, NodePath("Skeleton:B_R_Finger42"))
	same.get_animation("move").rotation_track_insert_key(missing, 0.0, Quaternion.IDENTITY)
	result = Binding.bind(same, target, root)
	check(result.library.has_animation("move") and result.warnings.has("move") and result.bridge == null, "같은 골격의 누락 손가락은 경고와 함께 직접 재생")
	check(result.library.get_animation("move").get_track_count() == target.get_bone_count(), "누락된 트랙만 제거")
	# 저장된 BoneMap을 통한 본 대응을 검사한다.
	var custom := humanoid("joint_", 1.0)
	var map := BoneMap.new()
	map.profile = SkeletonProfileHumanoid.new()
	for index in custom.get_bone_count():
		map.set_skeleton_bone_name(map.profile.get_bone_name(index), custom.get_bone_name(index))
	var custom_roles := Mapping.for_skeleton(custom, map)
	check(Mapping.validate(custom, custom_roles).is_empty() and custom_roles.Hips == "joint_Hips", "저장된 BoneMap이 이름 추정보다 우선")
	var map_config := ConfigFile.new()
	map_config.set_value("params", "_subresources", {"nodes": {"PATH:Skeleton": {"retarget/bone_map": map}}})
	map_config.save("res://output/motion_preview_checks/map_fixture.glb.import")
	check(Mapping.import_map("res://output/motion_preview_checks/map_fixture.glb").get_skeleton_bone_name("Hips") == "joint_Hips", "Godot 고급 임포트 BoneMap 읽기")
	custom.set_bone_parent(custom.find_bone("joint_LeftHand"), custom.find_bone("joint_Hips"))
	check(not Mapping.validate(custom, custom_roles).is_empty(), "이름이 맞아도 잘못된 계층은 거절")
	check(Mapping.unique_roles(PackedStringArray(["LeftArm", "upper_arm.L"]))["LeftUpperArm"] == "", "모호한 중복 이름은 거절")
	check(Mapping.role("upper_arm.L") == "LeftUpperArm" and Mapping.role("B_R_UpperArm") == "RightUpperArm", "보조 이름 매핑")
	# GLB에서 원본 기준 자세를 얻는 실제 경로도 검사한다.
	var source_root := Node3D.new()
	original.name = "Skeleton"
	source_root.add_child(original)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.skeleton = mesh.get_path_to(original) if mesh.is_inside_tree() else NodePath("../Skeleton")
	mesh.skin = original.create_skin_from_rest_transforms()
	source_root.add_child(mesh)
	var exporter := GLTFDocument.new()
	var state := GLTFState.new()
	var export_ok := exporter.append_from_scene(source_root, state) == OK and exporter.write_to_filesystem(state, "res://output/motion_preview_checks/source_fixture.glb") == OK
	check(export_ok, "원본 골격 GLB 생성")
	motion.take_over_path("res://output/motion_preview_checks/source_fixture.glb")
	var loaded := Binding.source_scene(motion)
	check(loaded != null and Binding.skeletons_in(loaded).size() == 1, "GLB 모션 원본 기준 자세 읽기")
	if loaded != null:
		loaded.free()
	source_root.free()
	custom.free()
	root.free()
	print("RETARGET_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
