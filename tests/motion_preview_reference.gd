extends SceneTree
const Reference = preload("res://addons/motion_preview/source_reference.gd")
const Binding = preload("res://addons/motion_preview/motion_binding.gd")
var checks := 0
var failures := 0
func check(ok: bool, label: String):
	checks += 1
	if not ok: failures += 1
	print("REFERENCE ","PASS " if ok else "FAIL ",label)
func rig() -> Skeleton3D:
	var result := Skeleton3D.new()
	var profile := SkeletonProfileHumanoid.new()
	for i in profile.bone_size: result.add_bone(profile.get_bone_name(i))
	for i in profile.bone_size:
		result.set_bone_parent(i,profile.find_bone(profile.get_bone_parent(i)))
		result.set_bone_rest(i,profile.get_reference_pose(i))
	result.reset_bone_poses()
	return result
func _initialize(): run.call_deferred()
func run():
	var world := Node3D.new(); root.add_child(world)
	var reference := rig(); reference.name="Reference";world.add_child(reference)
	var posed := rig();posed.name="Posed";world.add_child(posed)
	var hips := posed.find_bone("Hips")
	var rest := posed.get_bone_rest(hips)
	rest.basis = Basis(Vector3.UP,1.8)*rest.basis
	posed.set_bone_rest(hips,rest);posed.reset_bone_poses()
	var library := AnimationLibrary.new()
	var animation := Animation.new();animation.length=1
	var track := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(track,NodePath("Posed:Hips"))
	animation.rotation_track_insert_key(track,0,rest.basis.get_rotation_quaternion())
	animation.rotation_track_insert_key(track,1,Quaternion(Vector3.UP,2.4))
	library.add_animation(&"attack",animation)
	var reset := Animation.new()
	track=reset.add_track(Animation.TYPE_ROTATION_3D)
	reset.track_set_path(track,NodePath("Posed:Hips"))
	reset.rotation_track_insert_key(track,0,rest.basis.get_rotation_quaternion())
	library.add_animation(&"RESET",reset)
	var capture_player := AnimationPlayer.new();world.add_child(capture_player)
	preload("res://addons/motion_preview/rest_pose.gd").capture(capture_player,reset)
	var imported := Binding.source_scene(library) as Skeleton3D
	check(imported!=null and imported.get_bone_rest(hips).is_equal_approx(rest),"첫 프레임 RESET인 재현 골격 준비")
	var fixed := Reference.copy_matching(imported,reference)
	check(fixed!=null and fixed.get_bone_rest(hips).is_equal_approx(reference.get_bone_rest(hips)),"명시한 공급자 기준 자세 사용")
	var target := rig();target.name="Target";world.add_child(target)
	var result := Binding.bind(library,target,world,fixed)
	check(result.bridge==null and result.library.has_animation(&"attack"),"동일 리그는 불필요한 리타기팅 없음")
	var output := AnimationPlayer.new();world.add_child(output)
	output.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	output.add_animation_library(&"",result.library)
	var good := true
	for time in [0.0,.4,.8]:
		output.play(&"attack");output.seek(time,true);output.pause()
		good = good and target.get_bone_pose_rotation(hips).is_equal_approx(animation.rotation_track_interpolate(0,time))
	check(good,"준비 자세를 제거하지 않고 원본 키 그대로 재생")
	check(posed.get_bone_rest(hips).is_equal_approx(rest) and library.get_animation(&"attack")==animation,"원본 골격·모션 보존")
	var rotated_reference := rig()
	var root_index := rotated_reference.find_bone("Root")
	var hip_index := rotated_reference.find_bone("Hips")
	var hip_world := rotated_reference.get_bone_global_rest(hip_index)
	var carrier := Transform3D(Basis(Vector3.RIGHT,PI/2),Vector3.ZERO)
	rotated_reference.set_bone_rest(root_index,carrier)
	rotated_reference.set_bone_rest(hip_index,carrier.affine_inverse()*hip_world)
	var root_fixed := Reference.copy_matching(imported,rotated_reference)
	check(root_fixed!=null and root_fixed.get_bone_rest(root_index).is_equal_approx(imported.get_bone_rest(root_index)) and root_fixed.get_bone_global_rest(hip_index).is_equal_approx(hip_world),"루트 축이 달라도 변형 본의 모델 공간 bind 자세 유지")
	check(Reference.matches_target(root_fixed,rotated_reference),"명시한 원래 기준 모델은 직접 재생 판별 유지")
	root_fixed.free();rotated_reference.free()
	var incompatible := rig();incompatible.set_bone_parent(incompatible.find_bone("LeftUpperArm"),incompatible.find_bone("Hips"))
	check(Reference.copy_matching(imported,incompatible)==null,"부모 계층이 다른 기준 모델 거절")
	check(Reference.copy_matching(null,reference)==null,"유효하지 않은 기준 골격 거절")
	Reference.register_setting()
	var old: Variant=ProjectSettings.get_setting(Reference.SETTING,{})
	library.take_over_path("res://test/motions/attack.tres")
	ProjectSettings.set_setting(Reference.SETTING,{"res://test/":"res://broad.FBX","res://test/motions/":"res://specific.FBX"})
	check(Reference.configured_path(library)=="res://specific.FBX","가장 구체적인 모션 폴더 우선")
	ProjectSettings.set_setting(Reference.SETTING,{"res://test/../test/":"res://invalid.FBX"})
	check(Reference.configured_path(library).is_empty(),"정규 경로가 아닌 매핑 제외")
	ProjectSettings.set_setting(Reference.SETTING,old)
	fixed.free();imported.free();incompatible.free();world.free()
	print("MOTION_REFERENCE_COMPLETE checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)
