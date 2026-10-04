@tool
extends RefCounted


static func skeletons_in(node: Node) -> Array[Skeleton3D]:
	var result: Array[Skeleton3D] = []
	if node is Skeleton3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(skeletons_in(child))
	return result


static func bind(source: AnimationLibrary, skeleton: Skeleton3D, root: Node) -> Dictionary:
	var library := AnimationLibrary.new()
	var errors := {}
	var skipped := 0
	for name in source.get_animation_list():
		var original := source.get_animation(name)
		var animation := original.duplicate(true) as Animation
		var missing := PackedStringArray()
		var skeletal_tracks := 0
		# 스켈레톤 이외의 트랙은 복제본에서 제외해 메서드 등을 실행하지 않는다.
		for track in range(animation.get_track_count() - 1, -1, -1):
			var type := animation.track_get_type(track)
			var path := animation.track_get_path(track)
			if type not in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D,
				Animation.TYPE_SCALE_3D] or path.get_subname_count() != 1:
				animation.remove_track(track)
				skipped += 1
				continue
			var bone := String(path.get_subname(0))
			if skeleton.find_bone(bone) == -1:
				if bone not in missing:
					missing.append(bone)
				continue
			animation.track_set_path(track, NodePath("%s:%s" % [root.get_path_to(skeleton), bone]))
			skeletal_tracks += 1
		if not missing.is_empty():
			errors[name] = "스켈레톤 불일치: %d개 본 없음 (%s)" % [missing.size(), ", ".join(missing.slice(0, 3))]
		elif skeletal_tracks == 0:
			errors[name] = "재생할 스켈레톤 트랙이 없습니다."
		else:
			# 반복은 미리보기 복사본에만 설정한다. 원본 임포트 설정은 보존한다.
			animation.loop_mode = Animation.LOOP_LINEAR
			library.add_animation(name, animation)
	return {"library": library, "errors": errors, "skipped": skipped}
