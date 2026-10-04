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
 print("PORTABLE_EDITOR_COMPLETE checks=%d failures=%d" % [checks, failures])
 get_tree().quit(0 if failures == 0 else 1)
