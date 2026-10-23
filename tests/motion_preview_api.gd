extends SceneTree

const Preview = preload("res://addons/motion_preview/preview_control.gd")
const Catalog = preload("res://addons/motion_preview/model_catalog.gd")
var checks := 0
var failures := 0
var notices := {}
var pose_updates := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("API ", "PASS " if ok else "FAIL ", label)

func _initialize() -> void:
	run.call_deferred()

func make_target() -> Node3D:
	var target := Node3D.new()
	target.name = "Character"
	var skeleton := Skeleton3D.new()
	skeleton.name = "Rig"
	fill_humanoid(skeleton)
	target.add_child(skeleton)
	var modifier := RetargetModifier3D.new()
	modifier.profile = SkeletonProfileHumanoid.new()
	modifier.use_global_pose = false
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	skeleton.add_child(modifier)
	var deform := Skeleton3D.new()
	deform.name = "Deform"
	fill_humanoid(deform)
	modifier.add_child(deform)
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	target.add_child(mesh)
	return target

func fill_humanoid(skeleton: Skeleton3D) -> void:
	var profile := SkeletonProfileHumanoid.new()
	for index in profile.bone_size:
		skeleton.add_bone(profile.get_bone_name(index))
	for index in profile.bone_size:
		skeleton.set_bone_parent(index, profile.find_bone(profile.get_bone_parent(index)))
		skeleton.set_bone_rest(index, profile.get_reference_pose(index))
	skeleton.reset_bone_poses()

func make_library() -> AnimationLibrary:
	var clip := Animation.new()
	clip.length = 0.8
	var track := clip.add_track(Animation.TYPE_ROTATION_3D)
	clip.track_set_path(track, ^"Rig:Hips")
	clip.rotation_track_insert_key(track, 0.0, Quaternion.IDENTITY)
	clip.rotation_track_insert_key(track, 0.8, Quaternion(Vector3.UP, 1.0))
	var method := clip.add_track(Animation.TYPE_METHOD)
	clip.track_set_path(method, ^".")
	clip.track_insert_key(method, 0.2, {"method": &"queue_free", "args": []})
	var library := AnimationLibrary.new()
	library.add_animation(&"attack", clip)
	return library

func run() -> void:
	var preview := Preview.new()
	preview.set_selectors_visible(false)
	preview.set_original_materials(true)
	preview.set_playback_speed(1.5)
	for event in [&"motions_changed", &"motion_changed", &"time_changed", &"playback_changed", &"target_changed", &"load_failed"]:
		notices[event] = 0
	# Count signals with their actual arities.
	preview.motions_changed.connect(func(): notices[&"motions_changed"] += 1)
	preview.motion_changed.connect(func(_key): notices[&"motion_changed"] += 1)
	preview.time_changed.connect(func(_time, _length): notices[&"time_changed"] += 1)
	preview.playback_changed.connect(func(_playing): notices[&"playback_changed"] += 1)
	preview.target_changed.connect(func(): notices[&"target_changed"] += 1)
	preview.load_failed.connect(func(_message): notices[&"load_failed"] += 1)
	root.add_child(preview)
	check(not preview.has_motion() and preview.get_time() == 0.0 and preview.get_duration() == 0.0, "empty ready and empty getters")
	preview.play()
	preview.seek_time(1.0)
	check(not preview.is_playing(), "empty playback calls are safe")
	check(preview.get_playback_speed() == 1.5, "pre-ready playback configuration")
	var library := make_library()
	var target := make_target()
	var rig := target.get_node("Rig") as Skeleton3D
	var deform := rig.get_child(0).get_child(0) as Skeleton3D
	var callback := func():
		pose_updates += 1
		rig.advance(0.0)
	check(preview.set_prepared_target(target, target, {&"rpg": library}, callback), "prepared multi-skeleton target accepted")
	check(preview.get_motions() == PackedStringArray(["rpg/attack"]), "full namespaced motion keys")
	check(preview.get_selected_motion() == &"rpg/attack" and preview.has_motion(), "automatic initial selection")
	check(is_equal_approx(preview.get_duration(), 0.8), "actual .8 second clip length")
	preview.pause()
	await process_frame
	await process_frame
	preview.seek_time(0.4)
	check(not preview.is_playing() and is_equal_approx(preview.get_time(), 0.4), "seek pauses at seconds")
	check(rig.get_bone_pose_rotation(rig.find_bone("Hips")).angle_to(Quaternion.IDENTITY) > 0.1, "seek updates original prepared track path")
	await process_frame
	await process_frame
	check(deform.get_bone_pose_rotation(deform.find_bone("Hips")).angle_to(rig.get_bone_pose_rotation(rig.find_bone("Hips"))) < 0.001, "existing engine modifier updates deformation skeleton")
	check(pose_updates > 0, "adapter pose callback after seek")
	preview.seek_time(100)
	check(is_equal_approx(preview.get_time(), 0.8), "seek clamps at actual end")
	preview.seek_time(-2)
	check(preview.get_time() == 0.0, "seek clamps at zero")
	preview.set_looping(false)
	preview.set_playback_speed(2.0)
	preview.play()
	preview._process(0.2)
	check(is_equal_approx(preview.get_time(), 0.4), "manual playback uses public speed")
	preview._process(0.3)
	check(not preview.is_playing() and is_equal_approx(preview.get_time(), 0.8), "non-looping playback pauses at end")
	preview.play()
	check(preview.is_playing() and preview.get_time() == 0.0, "play restarts a finished non-looping clip")
	preview.set_looping(true)
	preview._process(0.5)
	check(preview.is_playing() and preview.get_time() < 0.8, "looping playback wraps")
	preview.pause()
	var time := preview.get_time()
	preview._process(0.2)
	check(preview.get_time() == time, "pause freezes time")
	preview.set_playback_speed(100)
	check(preview.get_playback_speed() == 3.0, "speed clamps to UI range")
	check(library.get_animation(&"attack").loop_mode == Animation.LOOP_NONE and library.get_animation(&"attack").get_track_count() == 2, "source loop and method track unchanged")
	check(is_instance_valid(target), "method tracks never execute")
	check(not preview.select_motion(&"missing") and preview.get_selected_motion() == &"rpg/attack", "invalid selection reports failure and preserves selection")
	var invalid := make_target()
	var mixer := AnimationPlayer.new()
	invalid.add_child(mixer)
	check(not preview.set_prepared_target(invalid, invalid, {&"rpg": library}), "unprepared AnimationPlayer rejected")
	check(invalid.get_parent() == null and is_instance_valid(target), "failed target stays caller-owned and previous preview remains")
	invalid.free()
	invalid = make_target()
	var bad := make_library()
	bad.get_animation(&"attack").track_set_path(0, ^"Missing:Hips")
	check(not preview.set_prepared_target(invalid, invalid, {&"rpg": bad}), "invalid bone paths rejected atomically")
	invalid.free()
	invalid = make_target()
	check(not preview.set_prepared_target(invalid, root, {&"rpg": library}), "external animation root rejected")
	invalid.free()
	invalid = make_target()
	check(not preview.set_prepared_target(invalid, invalid, {&"broken": 42}), "wrong library type rejected without engine error")
	invalid.free()
	invalid = make_target()
	invalid.queue_free()
	check(not preview.set_prepared_target(invalid, invalid, {}), "queued target rejected")
	var replacement := make_target()
	check(preview.set_prepared_target(replacement, replacement, {&"": library}), "default library supported")
	check(not is_instance_valid(target) and preview.get_motions() == PackedStringArray(["attack"]), "successful replacement frees previous target")
	var snapshot_count := preview.get_motions().size()
	library.add_animation(&"later", Animation.new())
	check(preview.get_motions().size() == snapshot_count, "prepared libraries are isolated snapshots")
	var invalid_script := make_target()
	invalid_script.set_script(load("res://addons/motion_preview/native_retarget.gd"))
	check(not preview.set_prepared_target(invalid_script, invalid_script, {}), "script-bearing prepared nodes rejected")
	invalid_script.free()
	preview.clear_preview()
	check(not is_instance_valid(replacement) and not preview.has_motion() and preview.get_selected_motion().is_empty(), "clear frees target and clears playback state")
	check(preview.get_motions().is_empty(), "clear returns to empty configured library")
	library.remove_animation(&"later")
	preview.set_animation_library(library)
	var safe := Node3D.new()
	var skeleton := Skeleton3D.new()
	skeleton.name = "Rig"
	skeleton.add_bone("Hips")
	safe.add_child(skeleton)
	skeleton.owner = safe
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	safe.add_child(mesh)
	mesh.owner = safe
	var packed := PackedScene.new()
	packed.pack(safe)
	var path := "res://output/motion_api_model.glb"
	DirAccess.make_dir_recursive_absolute("res://output")
	mesh.skeleton = NodePath("../Rig")
	mesh.skin = skeleton.create_skin_from_rest_transforms()
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	document.append_from_scene(safe, state)
	document.write_to_filesystem(state, path)
	var imported := GLTFState.new()
	document.append_from_file(path, imported)
	var imported_root := document.generate_scene(imported)
	for node in imported_root.find_children("*", "Node", true, false):
		node.owner = imported_root
	packed.pack(imported_root)
	packed.take_over_path(path)
	imported_root.free()
	safe.free()
	var preceding := make_target()
	preview.set_prepared_target(preceding, preceding, {&"rpg": library})
	check(preview.load_model(path), "public safe model loader after prepared mode")
	check(not is_instance_valid(preceding) and preview.get_motions() == PackedStringArray(["attack"]), "switch to safe loader restores library motion list")
	check(preview.select_motion(&"attack") and preview.get_duration() == 0.8, "public library binding and selection")
	var second := AnimationLibrary.new()
	var clip := Animation.new()
	clip.length = 1.25
	var t := clip.add_track(Animation.TYPE_ROTATION_3D)
	clip.track_set_path(t, ^"Rig:Hips")
	clip.rotation_track_insert_key(t, 0.0, Quaternion.IDENTITY)
	second.add_animation(&"other", clip)
	preview.set_animation_library(second)
	check(preview.get_motions() == PackedStringArray(["other"]) and preview.get_duration() == 1.25, "library replacement rebinds live target")
	library.add_animation(&"old", Animation.new())
	check(preview.get_motions() == PackedStringArray(["other"]), "old library signals disconnected")
	second.remove_animation(&"other")
	check(not preview.has_motion() and preview.get_duration() == 0.0, "live library removal invalidates playback")
	check(not preview.load_model("res://missing-model.tscn") and not preview.has_motion(), "invalid model load clears old target safely")
	preview.set_animation_library(null)
	check(preview.get_motions().is_empty(), "null library supported")
	var multi := make_target()
	var unrelated_rig := multi.get_node("Rig").get_child(0).get_child(0)
	unrelated_rig.reparent(multi, false)
	for node in multi.find_children("*", "Node", true, false):
		node.owner = multi
	var multi_scene := PackedScene.new()
	multi_scene.pack(multi)
	check(not Catalog.is_model(multi_scene), "general catalog still rejects unrelated skeletons")
	multi.free()
	var switching := make_target()
	preview.set_prepared_target(switching, switching, {&"rpg": make_library()})
	preview.set_animation_library(make_library())
	check(not is_instance_valid(switching) and not preview.has_motion(), "library setter releases prepared target before mode change")
	DirAccess.remove_absolute(path)
	var owned := make_target()
	preview.set_prepared_target(owned, owned, {&"rpg": make_library()})
	preview.queue_free()
	await process_frame
	check(not is_instance_valid(owned), "control teardown frees owned target")
	for event in notices:
		check(notices[event] > 0, "signal emitted: " + String(event))
	print("MOTION_API_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
