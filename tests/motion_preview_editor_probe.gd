@tool
extends EditorPlugin
const Preview = preload("res://addons/motion_preview/preview_control.gd")
var failures := 0
var checks := 0
func _enter_tree():
 run.call_deferred()
func check(ok: bool, label: String):
 checks += 1
 if not ok: failures += 1
 print("PROBE ", "PASS " if ok else "FAIL ", label)
func frames(count: int):
 for i in count: await get_tree().process_frame
func find_preview(node: Node) -> Node:
 if node.get_script() != null and node.get_script().resource_path.ends_with("preview_control.gd"):
  return node
 for child in node.get_children():
  var found = find_preview(child)
  if found != null: return found
 return null
func check_initial_framing(preview: Node, label: String):
 if preview == null or preview.model == null:
  check(false, label)
  return
 var initial_distance: float = preview.distance
 preview._frame_model()
 check(is_equal_approx(initial_distance, preview.distance), label)
func model_fits(preview: Node) -> bool:
 var mesh = preview.model.find_child("Body", true, false)
 var bounds: AABB = mesh.global_transform * mesh.get_aabb()
 var area := Rect2(Vector2.ZERO, Vector2(preview.viewport.size))
 for corner in 8:
  var point: Vector2 = preview.camera.unproject_position(bounds.get_endpoint(corner))
  if not area.has_point(point): return false
 return true
func capture(preview: Node, name: String):
 var args := OS.get_cmdline_user_args()
 var index := args.find("--capture-dir")
 if index < 0 or index + 1 >= args.size(): return
 await RenderingServer.frame_post_draw
 var image: Image = preview.viewport.get_texture().get_image()
 var path := args[index + 1].path_join(name + ".png")
 check(image != null and not image.is_empty() and image.save_png(path) == OK, "실제 렌더링 캡처: " + name)
func check_resize_framing():
 var holder := Control.new()
 get_editor_interface().get_base_control().add_child(holder)
 holder.position = Vector2(100, 100)
 var preview := Preview.new()
 preview.library = load("res://fixture_motion.tres")
 preview.model_paths = PackedStringArray(["res://fixture_model.glb"])
 preview.preferred_model = "res://fixture_model.glb"
 holder.add_child(preview)
 preview.size = Vector2(420, 600)
 await frames(20)
 check(model_fits(preview), "레이아웃 전에 자동 선택한 모델 전체가 표시 영역에 들어옴")
 var initial_distance: float = preview.distance
 await capture(preview, "initial")
 preview._set_status("경고: 3개 손가락 본을 적용하지 못했습니다. 해당 부위의 움직임이 생략됩니다.", "warning")
 check(preview.status.get_theme_color("font_color") == Color(1.0, 0.78, 0.3), "경고 메시지는 노란색")
 await capture(preview, "warning")
 var incompatible := Animation.new()
 var track := incompatible.add_track(Animation.TYPE_ROTATION_3D)
 incompatible.track_set_path(track, NodePath("Skeleton:Tentacle"))
 incompatible.rotation_track_insert_key(track, 0.0, Quaternion.IDENTITY)
 var original_library: AnimationLibrary = preview.library
 var bad_library := AnimationLibrary.new()
 bad_library.add_animation("incompatible", incompatible)
 preview.library = bad_library
 preview._fill_clips()
 preview._bind_library()
 check(preview.play_button.disabled and preview.status.get_theme_color("font_color") == Color(1.0, 0.35, 0.35), "재생 불가능한 조합은 빨간 오류와 비활성 재생 버튼")
 preview.library = original_library
 preview._fill_clips()
 preview._bind_library()
 check(not preview.play_button.disabled and not preview.status.has_theme_color_override("font_color"), "정상 클립 복귀 시 오류 색상 해제")
 preview._frame_model()
 await frames(5)
 check(is_equal_approx(initial_distance, preview.distance), "초기 구도와 수동 초기화 구도가 일치")
 await capture(preview, "reset")
 preview.size.x = 900
 await frames(10)
 var wide_distance: float = preview.distance
 check(preview.viewport.size.x == preview.viewport.size.y and model_fits(preview), "넓어진 표시 영역은 정사각형이며 모델 전체 표시")
 preview.size.x = 320
 await frames(10)
 check(preview.viewport.size.x == preview.viewport.size.y and is_equal_approx(preview.distance, wide_distance) and model_fits(preview), "좁아진 표시 영역도 정사각형이며 모델 구도 유지")
 await capture(preview, "narrow")
 var wheel := InputEventMouseButton.new()
 wheel.button_index = MOUSE_BUTTON_WHEEL_UP
 wheel.pressed = true
 preview._view_input(wheel)
 preview.dragging = true
 var drag := InputEventMouseMotion.new()
 drag.relative = Vector2(30, 10)
 preview._view_input(drag)
 preview.dragging = false
 var user_distance: float = preview.distance
 var user_orbit: Vector2 = preview.orbit
 preview.size.x = 600
 await frames(10)
 check(is_equal_approx(user_distance, preview.distance) and user_orbit.is_equal_approx(preview.orbit), "리사이즈 후 사용자 확대·회전 유지")
 preview._frame_model()
 preview.size.x = 320
 await frames(10)
 check(model_fits(preview), "시점 초기화 후 자동 구도 보정 재개")
 holder.queue_free()
 await frames(5)
func native_humanoid(prefix: String, scale: float) -> Skeleton3D:
 var skeleton := Skeleton3D.new()
 var profile := SkeletonProfileHumanoid.new()
 for index in profile.bone_size:
  skeleton.add_bone(prefix + String(profile.get_bone_name(index)))
 for index in profile.bone_size:
  skeleton.set_bone_parent(index, profile.find_bone(profile.get_bone_parent(index)))
  var rest := profile.get_reference_pose(index)
  rest.origin *= scale
  skeleton.set_bone_rest(index, rest)
 skeleton.reset_bone_poses()
 return skeleton
func check_native_preview():
 var root := Node3D.new()
 root.name = "NativePreviewModel"
 var target := native_humanoid("", 2.0)
 root.add_child(target)
 target.owner = root
 var mesh := MeshInstance3D.new()
 mesh.mesh = BoxMesh.new()
 root.add_child(mesh)
 mesh.owner = root
 var packed := PackedScene.new()
 packed.pack(root)
 var mesh_node := root.get_child(1) as MeshInstance3D
 mesh_node.skeleton = NodePath("../" + String(target.name))
 mesh_node.skin = target.create_skin_from_rest_transforms()
 var document := GLTFDocument.new()
 var state := GLTFState.new()
 document.append_from_scene(root, state)
 document.write_to_filesystem(state, "res://native_model.glb")
 get_editor_interface().get_resource_filesystem().scan()
 await frames(30)
 root.free()
 var source := native_humanoid("mixamorig_", 1.0)
 var clip := Animation.new()
 clip.length = 1.0
 var track := clip.add_track(Animation.TYPE_ROTATION_3D)
 clip.track_set_path(track, NodePath("Skeleton:mixamorig_LeftUpperArm"))
 var index := source.find_bone("mixamorig_LeftUpperArm")
 var rest := source.get_bone_rest(index).basis.get_rotation_quaternion()
 clip.rotation_track_insert_key(track, 0.0, rest * Quaternion(Vector3.UP, 0.3))
 clip.rotation_track_insert_key(track, 1.0, rest * Quaternion(Vector3.UP, 0.9))
 var library := AnimationLibrary.new()
 library.add_animation("native", clip)
 var direct := Animation.new()
 direct.length = 1.0
 var direct_track := direct.add_track(Animation.TYPE_ROTATION_3D)
 direct.track_set_path(direct_track, NodePath("Skeleton:LeftUpperArm"))
 var direct_pose := Quaternion(Vector3.RIGHT, 0.6)
 direct.rotation_track_insert_key(direct_track, 0.0, direct_pose)
 direct.rotation_track_insert_key(direct_track, 1.0, direct_pose)
 library.add_animation("direct", direct)
 var holder := Control.new()
 get_editor_interface().get_base_control().add_child(holder)
 var preview := Preview.new()
 preview.library = library
 preview.model_paths = PackedStringArray(["res://native_model.glb"])
 preview.preferred_model = "res://native_model.glb"
 holder.add_child(preview)
 preview.source_model = source
 preview.source_skeleton = source
 preview._bind_library()
 preview.clip_menu.select(1)
 preview._play_clip()
 await frames(5)
 check(preview.retarget_bridge != null and not preview.play_button.disabled, "에디터 미리보기에서 기본 리타게팅 자동 재생")
 check(preview.status.text.contains("Godot") and preview.status.get_theme_color("font_color") == Color(1.0, 0.78, 0.3), "엔진 리타게팅 경고 표시")
 preview._seek(0.0)
 await frames(3)
 var target_index := preview.skeleton.find_bone("LeftUpperArm")
 var first: Quaternion = preview.skeleton.get_bone_pose_rotation(target_index)
 check(first.angle_to(preview.skeleton.get_bone_rest(target_index).basis.get_rotation_quaternion()) > 0.1, "일시정지 시 첫 프레임의 실제 자세 유지")
 preview._seek(0.6)
 await frames(3)
 check(preview.skeleton.get_bone_pose_rotation(target_index).angle_to(first) > 0.1, "에디터 시간 슬라이더로 리타게팅 갱신")
 preview._seek(0.7)
 preview.clip_menu.select(0)
 preview._play_clip()
 await frames(3)
 check(preview.skeleton.get_bone_pose_rotation(target_index).angle_to(direct_pose) < 0.01, "리타게팅에서 직접 재생으로 바꾸면 이전 보정이 덮어쓰지 않음")
 check(not preview.status.has_theme_color_override("font_color"), "직접 재생 클립으로 전환하면 경고 해제")
 holder.queue_free()
 await frames(3)
func check_file_logging():
 var logger = preload("res://addons/motion_preview/performance_log.gd")
 check(not ProjectSettings.get_setting(logger.SETTING, true), "개발자 파일 로그는 기본 off")
 ProjectSettings.set_setting(logger.SETTING, true)
 logger.write("file logging probe")
 var path: String = logger.DIRECTORY.path_join(logger.FILE_NAME)
 check(FileAccess.file_exists(path) and FileAccess.get_file_as_string(path).contains("file logging probe"), "옵션을 켜면 로그를 파일에 자동 저장")
 var before := FileAccess.get_file_as_string(path)
 ProjectSettings.set_setting(logger.SETTING, false)
 logger.write("disabled logging probe")
 check(FileAccess.get_file_as_string(path) == before, "옵션을 끄면 즉시 파일 기록 중단")
 var rotated := true
 for index in 5:
  var file := FileAccess.open(path, FileAccess.WRITE)
  file.seek(logger.MAX_BYTES - 1)
  file.store_8(32)
  file.close()
  rotated = logger._append("rotation probe\n") and rotated
 check(rotated and FileAccess.file_exists(path + ".3") and not FileAccess.file_exists(path + ".4") and FileAccess.get_file_as_string(path) == "rotation probe\n", "로그 순환은 이전 파일 3개만 유지")

func check_log_settings_button():
 var inspector := EditorInspector.new()
 get_editor_interface().get_base_control().add_child(inspector)
 inspector.edit(ProjectSettings)
 await frames(3)
 var property_script = preload("res://addons/motion_preview/log_settings_property.gd")
 var found: EditorProperty
 for node in inspector.find_children("*", "EditorProperty", true, false):
  if node.get_script() == property_script:
   found = node
   break
 check(found != null and found.open_button.text == "로그 폴더 열기", "로그 저장 옵션과 같은 행에 폴더 열기 버튼 생성")
 if found != null:
  found.enabled_toggle.set_pressed(true)
  await frames(2)
  check(ProjectSettings.get_setting("addons/motion_preview/developer/save_performance_logs"), "폴더 버튼 추가 후 로그 저장 체크박스 편집 유지")
  found.enabled_toggle.set_pressed(false)
 inspector.queue_free()
 await frames(2)

func check_imported_pair():
 var catalog = preload("res://addons/motion_preview/model_catalog.gd")
 check(catalog.accepts_path("res://model.FBX") and catalog.accepts_path("res://model.GLB") and not catalog.accepts_path("res://model.tscn") and not catalog.accepts_path("res://model.scn") and not catalog.accepts_path("res://model.gltf"), "모델 파일은 FBX·GLB만 허용")
 var path := "res://native_model.glb"
 var packed: PackedScene = load(path)
 var instance := packed.instantiate()
 var driver: Skeleton3D = catalog.driving_skeleton(instance)
 var deform := driver.duplicate() as Skeleton3D
 for child in deform.get_children(): child.free()
 deform.name = "OriginalSkeleton"
 var modifier := RetargetModifier3D.new()
 modifier.profile = SkeletonProfileHumanoid.new()
 modifier.use_global_pose = false
 driver.add_child(modifier)
 modifier.add_child(deform)
 for mesh in instance.find_children("*", "MeshInstance3D", true, false):
  mesh.skeleton = mesh.get_path_to(deform)
 for node in instance.find_children("*", "Node", true, false): node.owner = instance
 var paired := PackedScene.new()
 paired.pack(instance)
 check(catalog.is_model(paired), "임포트 리타게팅 골격 두 개는 모델 후보로 허용")
 catalog.clear_preview_scene_cache()
 paired.take_over_path(path)
 var library := AnimationLibrary.new()
 var clip := Animation.new()
 clip.length = 1.0
 var track := clip.add_track(Animation.TYPE_ROTATION_3D)
 clip.track_set_path(track, ^"Skeleton:LeftUpperArm")
 var index := driver.find_bone("LeftUpperArm")
 var rest := driver.get_bone_rest(index).basis.get_rotation_quaternion()
 clip.rotation_track_insert_key(track, 0.0, rest)
 clip.rotation_track_insert_key(track, 1.0, rest * Quaternion(Vector3.UP, 0.8))
 library.add_animation("direct", clip)
 var holder := Control.new()
 get_editor_interface().get_base_control().add_child(holder)
 var preview := Preview.new()
 preview.library = library
 preview.model_paths = PackedStringArray([path])
 preview.preferred_model = path
 holder.add_child(preview)
 await frames(5)
 var actual := preview.model.find_child("OriginalSkeleton", true, false) as Skeleton3D
 check(preview.has_motion() and preview.model.find_children("*", "Skeleton3D", true, false).size() == 2 and actual.get_parent() is RetargetModifier3D, "일반 로더가 두 골격과 기존 RetargetModifier를 보존")
 preview.seek_time(0.1)
 await frames(3)
 var first: Quaternion = actual.get_bone_pose_rotation(index)
 preview.seek_time(0.8)
 await frames(3)
 var second: Quaternion = actual.get_bone_pose_rotation(index)
 check(first.angle_to(second) > 0.2, "시간 이동이 실제 메시용 골격의 자세를 변경")
 await frames(5)
 check(not preview.is_playing() and second.angle_to(actual.get_bone_pose_rotation(index)) < 0.001, "일시정지 상태에서도 변형 자세 유지")
 var source := native_humanoid("mixamorig_", 1.0)
 var native_clip := clip.duplicate(true) as Animation
 native_clip.track_set_path(0, ^"Skeleton:mixamorig_LeftUpperArm")
 var native_library := AnimationLibrary.new()
 native_library.add_animation("native", native_clip)
 preview.set_animation_library(native_library)
 preview.source_model = source
 preview.source_skeleton = source
 preview._bind_library()
 check(preview.native_active and preview.retarget_bridge != null, "외부 골격에서 임포트 구동 골격으로 리타게팅 연결")
 preview.seek_time(0.1)
 await frames(3)
 first = actual.get_bone_pose_rotation(index)
 preview.seek_time(0.8)
 await frames(3)
 check(first.angle_to(actual.get_bone_pose_rotation(index)) > 0.2, "추가 리타게팅 뒤에도 기존 변형 골격까지 자세 전달")
 holder.queue_free()
 await frames(3)
 deform.owner = null
 deform.reparent(instance, false)
 deform.owner = instance
 var unrelated := PackedScene.new()
 unrelated.pack(instance)
 check(not catalog.is_model(unrelated), "서로 연결되지 않은 다중 골격은 계속 거부")
 instance.free()
 catalog.clear_preview_scene_cache()

func run():
 await frames(120)
 check_file_logging()
 await check_log_settings_button()
 var interface = get_editor_interface()
 interface.get_file_system_dock().navigate_to_path("res://fixture_motion.tres")
 await frames(20)
 var preview = find_preview(interface.get_inspector())
 check(preview != null, "파일 선택으로 인스펙터 미리보기 생성")
 if preview != null:
  check(preview.model_menu.item_count == 2, "프로젝트 전용 코드 없이 생성 모델 자동 탐색")
  preview.model_menu.select(1)
  preview.model_menu.item_selected.emit(1)
  await frames(10)
  preview = find_preview(interface.get_inspector())
  check(preview != null and preview.player != null and not preview.play_button.disabled, "에디터 모델 선택 후 재생")
  if preview != null and preview.player != null:
   var previous_model = preview.model
   preview.update_models(preview.model_paths)
   check(preview.model == previous_model, "목록 갱신 시 변경 없는 모델 인스턴스 재사용")
   var binding = preload("res://addons/motion_preview/motion_binding.gd")
   var first = binding._model_skeleton("res://fixture_model.glb")
   var second = binding._model_skeleton("res://fixture_model.glb")
   check(first is Skeleton3D and second is Skeleton3D and first != second and first.get_child_count() == 0, "기준 모델 캐시는 메시 없이 독립 골격을 반환")
   first.set_bone_pose_rotation(0, Quaternion(Vector3.UP, 0.8))
   check(second.get_bone_pose_rotation(0).angle_to(first.get_bone_pose_rotation(0)) > 0.1, "캐시에서 복원한 골격 사이에 자세를 공유하지 않음")
   first.free()
   second.free()
   preview.timeline.value = 0.5
   check(preview.skeleton.get_bone_pose_rotation(0).angle_to(Quaternion.IDENTITY) > 0.1, "에디터에서 실제 본 자세 적용")
  var catalog = preload("res://addons/motion_preview/model_catalog.gd")
  var retained_scene = weakref(catalog._preview_scene)
  var retained_scene_id: int = catalog._preview_scene.get_instance_id()
  var library = AnimationLibrary.new()
  library.add_animation("second", load("res://fixture_motion.tres").get_animation("turn"))
  interface.edit_resource(library)
  await frames(10)
  preview = find_preview(interface.get_inspector())
  check(preview != null and preview.model_menu.selected == 1 and preview.player != null, "다른 리소스에서도 모델 선택 유지")
  check_initial_framing(preview, "자동 선택 모델의 초기 구도가 시점 초기화와 일치")
  check(retained_scene.get_ref() != null and catalog._preview_scene.get_instance_id() == retained_scene_id, "인스펙터 교체 후에도 동일한 모델 PackedScene 유지")
  var before_refresh: int = preview.model.get_instance_id()
  preview.refresh_models(preview.model_paths)
  check(preview.model.get_instance_id() != before_refresh and preview.has_motion(), "파일 수정 시각이 같아도 새로 고침은 표시 모델과 바인딩 갱신")
  interface.set_plugin_enabled("motion_preview", false)
  await frames(10)
  check(catalog._preview_scene == null, "플러그인 해제 시 모델 리소스 캐시 해제")
  check(find_preview(interface.get_inspector()) == null, "플러그인 해제 시 미리보기 제거")
  interface.set_plugin_enabled("motion_preview", true)
  await frames(20)
  interface.edit_resource(load("res://fixture_motion.tres"))
  await frames(10)
  preview = find_preview(interface.get_inspector())
  check(preview != null and preview.model_menu.selected == 1 and preview.player != null, "재활성화 후 마지막 모델 복원")
  check_initial_framing(preview, "재활성화한 모델의 초기 구도가 시점 초기화와 일치")
 var catalog = preload("res://addons/motion_preview/model_catalog.gd")
 catalog.clear_preview_scene_cache()
 check(catalog._preview_scene == null and catalog._preview_scene_path.is_empty(), "새로 고침용 캐시 무효화는 경로와 모델 모두 제거")
 await check_resize_framing()
 await check_native_preview()
 await check_imported_pair()
 print("PORTABLE_EDITOR_COMPLETE checks=%d failures=%d" % [checks, failures])
 get_tree().quit(0 if failures == 0 else 1)
