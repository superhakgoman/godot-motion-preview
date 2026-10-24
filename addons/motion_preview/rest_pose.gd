@tool
extends RefCounted

const META := &"motion_preview_skeleton_v1"


# AnimationLibrary does not retain Skeleton3D topology. Store only immutable
# skeleton data on its RESET animation during the same import that made it.
static func capture(player: AnimationPlayer, reset: Animation) -> void:
	var animation_root := player.get_node_or_null(player.root_node)
	if animation_root == null:
		return
	var skeleton: Skeleton3D
	var paths := PackedStringArray()
	for track in reset.get_track_count():
		if not _bone_track(reset, track):
			continue
		var path := reset.track_get_path(track)
		var node_path := String(path.get_concatenated_names())
		var node: Node = animation_root if node_path.is_empty() else animation_root.get_node_or_null(NodePath(node_path))
		if not node is Skeleton3D or (skeleton != null and skeleton != node):
			return
		skeleton = node
		if node_path not in paths:
			paths.append(node_path)
	if skeleton == null:
		return
	var names := PackedStringArray()
	var parents := PackedInt32Array()
	var rests: Array[Transform3D] = []
	for index in skeleton.get_bone_count():
		names.append(skeleton.get_bone_name(index))
		parents.append(skeleton.get_bone_parent(index))
		rests.append(skeleton.get_bone_rest(index))
	reset.set_meta(META, {"names": names, "parents": parents, "rests": rests, "paths": paths,
		"space": preload("native_retarget.gd").skeleton_space(skeleton), "motion_scale": skeleton.motion_scale})


static func skeleton_from_reset(library: AnimationLibrary) -> Skeleton3D:
	if not library.has_animation(&"RESET"):
		return null
	var reset := library.get_animation(&"RESET")
	var data: Variant = reset.get_meta(META, null)
	if not data is Dictionary or not data.get("names") is PackedStringArray or not data.get("parents") is PackedInt32Array or not data.get("rests") is Array or not data.get("paths") is PackedStringArray or not data.get("space") is Transform3D:
		return null
	var count: int = data.names.size()
	if count == 0 or count > 4096 or data.parents.size() != count or data.rests.size() != count or float(data.get("motion_scale", 0)) <= 0:
		return null
	var skeleton := Skeleton3D.new()
	skeleton.transform = data.space
	skeleton.motion_scale = float(data.motion_scale)
	for index in count:
		if data.names[index].is_empty() or skeleton.find_bone(data.names[index]) >= 0 or not data.rests[index] is Transform3D or data.parents[index] < -1 or data.parents[index] >= count or data.parents[index] == index:
			skeleton.free()
			return null
		skeleton.add_bone(data.names[index])
	for index in count:
		var ancestor: int = data.parents[index]
		var seen := {}
		while ancestor >= 0:
			if ancestor == index or seen.has(ancestor):
				skeleton.free()
				return null
			seen[ancestor] = true
			ancestor = data.parents[ancestor]
		skeleton.set_bone_parent(index, data.parents[index])
		skeleton.set_bone_rest(index, data.rests[index])
	var found := false
	for track in reset.get_track_count():
		if not _bone_track(reset, track):
			continue
		var path := reset.track_get_path(track)
		var index := skeleton.find_bone(path.get_subname(0))
		if path.is_absolute() or String(path.get_concatenated_names()) not in data.paths or index < 0 or reset.track_get_key_count(track) == 0:
			skeleton.free()
			return null
		var rest := skeleton.get_bone_rest(index)
		match reset.track_get_type(track):
			Animation.TYPE_POSITION_3D:
				rest.origin = reset.position_track_interpolate(track, 0.0) * skeleton.motion_scale
			Animation.TYPE_ROTATION_3D:
				rest.basis = Basis(reset.rotation_track_interpolate(track, 0.0)) * Basis.from_scale(rest.basis.get_scale())
			Animation.TYPE_SCALE_3D:
				rest.basis = Basis(rest.basis.get_rotation_quaternion()) * Basis.from_scale(reset.scale_track_interpolate(track, 0.0))
		skeleton.set_bone_rest(index, rest)
		found = true
	if not found:
		skeleton.free()
		return null
	skeleton.reset_bone_poses()
	skeleton.set_meta("_motion_preview_rest_mode", "imported_RESET")
	return skeleton


static func _bone_track(animation: Animation, track: int) -> bool:
	return animation.track_get_type(track) in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D] and animation.track_get_path(track).get_subname_count() == 1
