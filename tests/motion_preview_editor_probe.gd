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
 var mesh = preview.model.get_node("Body")
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
 preview.model_paths = PackedStringArray(["res://fixture_model.tscn"])
 preview.preferred_model = "res://fixture_model.tscn"
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
 check(model_fits(preview), "넓어진 표시 영역에서 모델 전체 표시")
 preview.size.x = 320
 await frames(10)
 check(preview.distance > wide_distance and model_fits(preview), "좁아진 표시 영역에 맞춰 카메라 거리 보정")
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
 ResourceSaver.save(packed, "res://native_model.tscn")
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
 preview.model_paths = PackedStringArray(["res://native_model.tscn"])
 preview.preferred_model = "res://native_model.tscn"
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
func run():
 await frames(120)
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
   preview.timeline.value = 0.5
   check(preview.skeleton.get_bone_pose_rotation(0).angle_to(Quaternion.IDENTITY) > 0.1, "에디터에서 실제 본 자세 적용")
  var library = AnimationLibrary.new()
  library.add_animation("second", load("res://fixture_motion.tres").get_animation("turn"))
  interface.edit_resource(library)
  await frames(10)
  preview = find_preview(interface.get_inspector())
  check(preview != null and preview.model_menu.selected == 1 and preview.player != null, "다른 리소스에서도 모델 선택 유지")
  check_initial_framing(preview, "자동 선택 모델의 초기 구도가 시점 초기화와 일치")
  interface.set_plugin_enabled("motion_preview", false)
  await frames(10)
  check(find_preview(interface.get_inspector()) == null, "플러그인 해제 시 미리보기 제거")
  interface.set_plugin_enabled("motion_preview", true)
  await frames(20)
  interface.edit_resource(load("res://fixture_motion.tres"))
  await frames(10)
  preview = find_preview(interface.get_inspector())
  check(preview != null and preview.model_menu.selected == 1 and preview.player != null, "재활성화 후 마지막 모델 복원")
  check_initial_framing(preview, "재활성화한 모델의 초기 구도가 시점 초기화와 일치")
 await check_resize_framing()
 await check_native_preview()
 print("PORTABLE_EDITOR_COMPLETE checks=%d failures=%d" % [checks, failures])
 get_tree().quit(0 if failures == 0 else 1)
