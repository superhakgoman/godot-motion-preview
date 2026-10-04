@tool
extends Node3D

# 모션 → source 복사본 → 엔진 보정 → target 복사본 → 화면의 destination 모델.
# 두 복사본의 본 이름을 표준화해 RetargetModifier3D의 역할별 대응을 구성한다.
# 결과 자세를 본 인덱스로 전달해 화면 모델의 본 이름과 Skin 바인딩을 보존한다.
# 복사본은 메모리에서 재사용하며 모델/라이브러리 교체 또는 미리보기 종료 시 제거한다.
var source: Skeleton3D
var target: Skeleton3D
var destination: Skeleton3D
var modifier: RetargetModifier3D
var source_names := {}
var target_indices := {}


func configure(original: Skeleton3D, model: Skeleton3D, source_roles: Dictionary, target_roles: Dictionary) -> void:
	destination = model
	source = _copy_skeleton(original, source_roles, source_names)
	source.name = "Source"
	source.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	var unused := {}
	target = _copy_skeleton(model, target_roles, unused)
	target.name = "Target"
	var src_hips := source.find_bone("Hips")
	var dst_hips := target.find_bone("Hips")
	var source_height := absf(source.get_bone_global_rest(src_hips).origin.y) if src_hips >= 0 else 0.0
	var target_height := absf(target.get_bone_global_rest(dst_hips).origin.y) if dst_hips >= 0 else 0.0
	if source_height > 0.001 and target_height > 0.001:
		# AnimationPlayer도 source.motion_scale로 위치 트랙을 곱하므로
		# 소스 값은 보존하고 리타게팅의 비율만 대상 프록시에 설정한다.
		target.motion_scale = source.motion_scale * target_height / source_height
	for role in target_roles:
		var bone: String = target_roles[role]
		if not bone.is_empty() and source_roles.get(role, "") != "":
			target_indices[model.find_bone(bone)] = target.find_bone(role)
	modifier = RetargetModifier3D.new()
	modifier.profile = SkeletonProfileHumanoid.new()
	# 로컬 자세를 전달해 대상 골격의 체형을 유지한다.
	modifier.use_global_pose = false
	modifier.modification_processed.connect(_copy_result)
	# 엔진이 요구하는 구조: source Skeleton3D → modifier → target Skeleton3D.
	source.add_child(modifier)
	modifier.add_child(target)
	add_child(source)


# 모든 본을 복사해 골격의 부모 관계와 기준 자세를 보존한다.
# source의 트랙은 보존된 골격에서 재생하고, 엔진은 표준 역할에 대응된 자세를 전달한다.
static func _copy_skeleton(original: Skeleton3D, roles: Dictionary, names: Dictionary) -> Skeleton3D:
	var copy := Skeleton3D.new()
	for index in original.get_bone_count():
		var name := "_Unmapped_%d" % index
		for role in roles:
			if roles[role] == original.get_bone_name(index):
				name = role
				break
		copy.add_bone(name)
		names[original.get_bone_name(index)] = name
	for index in original.get_bone_count():
		copy.set_bone_parent(index, original.get_bone_parent(index))
		copy.set_bone_rest(index, original.get_bone_rest(index))
	copy.reset_bone_poses()
	copy.motion_scale = original.motion_scale
	return copy


func reset() -> void:
	# 클립 전환 시 이전 보정을 비활성화하고 두 골격의 자세를 초기화한다.
	modifier.active = false
	source.reset_bone_poses()
	target.reset_bone_poses()


func update() -> void:
	modifier.active = true
	source.advance(0.0)


func _copy_result() -> void:
	# 엔진의 완료 신호를 받아 갱신된 결과 자세를 화면 모델에 복사한다.
	if not is_instance_valid(destination):
		return
	for index in target_indices:
		destination.set_bone_pose(index, target.get_bone_pose(target_indices[index]))
