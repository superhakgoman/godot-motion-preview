@tool
extends RefCounted


# Skin의 본 대응과 현재 본 자세로 정점을 변환해 화면에 그려지는 모델의 범위를 구한다.
# 구도를 계산할 때만 호출하며 계산 결과는 모델의 메시나 Skin에 저장하지 않는다.
static func mesh_bounds(mesh: MeshInstance3D) -> AABB:
	var reference := mesh.get_skin_reference()
	var skeleton := mesh.get_node_or_null(mesh.skeleton) as Skeleton3D
	if reference == null or skeleton == null:
		return mesh.global_transform * mesh.get_aabb()
	var skin := reference.get_skin()
	var transforms: Array[Transform3D] = []
	for bind in skin.get_bind_count():
		var name := skin.get_bind_name(bind)
		var bone := skeleton.find_bone(name) if not name.is_empty() else skin.get_bind_bone(bind)
		if bone < 0 or bone >= skeleton.get_bone_count():
			return mesh.global_transform * mesh.get_aabb()
		transforms.append(skeleton.get_bone_global_pose(bone) * skin.get_bind_pose(bind))
	var bounds := AABB()
	var found := false
	for surface in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] != null else PackedInt32Array()
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
		var influences := 8 if mesh.mesh.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS else 4
		var has_weights := bones.size() == vertices.size() * influences and weights.size() == bones.size()
		for vertex in vertices.size():
			var point := vertices[vertex]
			if has_weights:
				point = Vector3.ZERO
				for influence in influences:
					var index := vertex * influences + influence
					if weights[index] > 0 and bones[index] >= 0 and bones[index] < transforms.size():
						point += (transforms[bones[index]] * vertices[vertex]) * weights[index]
			point = mesh.global_transform * point
			bounds = bounds.expand(point) if found else AABB(point, Vector3.ZERO)
			found = true
	return bounds if found else mesh.global_transform * mesh.get_aabb()
