@tool
extends VBoxContainer

const Catalog = preload("model_catalog.gd")
const Binding = preload("motion_binding.gd")

signal model_selected(path: String)
signal refresh_requested

var library: AnimationLibrary
var model_paths := PackedStringArray()
var preferred_model := ""
var model_menu: OptionButton
var clip_menu: OptionButton
var status: Label
var play_button: Button
var speed: SpinBox
var timeline: HSlider
var original_materials: CheckBox
var view_container: SubViewportContainer
var viewport: SubViewport
var world: Node3D
var camera: Camera3D
var model: Node3D
var skeleton: Skeleton3D
var player: AnimationPlayer
var binding_errors := {}
var binding_warnings := {}
var source_model: Node
var source_skeleton: Skeleton3D
var retarget_bridge: Node3D
var native_clips := {}
var native_active := false
var playing := true
var orbit := Vector2(0.0, 0.12)
var distance := 3.0
var target := Vector3.ZERO
var dragging := false
var auto_frame := true


func _ready() -> void:
	_build_ui()
	_build_world()
	_load_source_skeleton()
	library.changed.connect(_library_changed)
	library.animation_added.connect(_clips_changed)
	library.animation_removed.connect(_clips_changed)
	library.animation_renamed.connect(_clips_renamed)
	library.animation_changed.connect(_clips_changed)
	update_models(model_paths)


func _exit_tree() -> void:
	if is_instance_valid(source_model):
		source_model.free()
	if is_instance_valid(library) and library.changed.is_connected(_library_changed):
		library.changed.disconnect(_library_changed)
		library.animation_added.disconnect(_clips_changed)
		library.animation_removed.disconnect(_clips_changed)
		library.animation_renamed.disconnect(_clips_renamed)
		library.animation_changed.disconnect(_clips_changed)


func _build_ui() -> void:
	var title := Label.new()
	title.text = "모션 미리보기"
	add_child(title)
	var row := HBoxContainer.new()
	add_child(row)
	model_menu = OptionButton.new()
	model_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	model_menu.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	model_menu.item_selected.connect(_model_chosen)
	row.add_child(model_menu)
	var refresh := Button.new()
	refresh.text = "↻"
	refresh.tooltip_text = "모델 목록 새로 고침"
	refresh.pressed.connect(func(): refresh_requested.emit())
	row.add_child(refresh)
	clip_menu = OptionButton.new()
	clip_menu.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	clip_menu.item_selected.connect(func(_index: int): _play_clip())
	add_child(clip_menu)
	view_container = SubViewportContainer.new()
	view_container.custom_minimum_size = Vector2(0, 260)
	view_container.stretch = true
	view_container.mouse_filter = Control.MOUSE_FILTER_STOP
	view_container.gui_input.connect(_view_input)
	view_container.resized.connect(_resize_view)
	view_container.mouse_exited.connect(func(): dragging = false)
	add_child(view_container)
	viewport = SubViewport.new()
	viewport.size = Vector2i(320, 260)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view_container.add_child(viewport)
	timeline = HSlider.new()
	timeline.step = 0.001
	timeline.value_changed.connect(_seek)
	add_child(timeline)
	var controls := HBoxContainer.new()
	add_child(controls)
	play_button = Button.new()
	play_button.text = "일시정지"
	play_button.pressed.connect(_toggle_play)
	controls.add_child(play_button)
	var reset := Button.new()
	reset.text = "시점 초기화"
	reset.pressed.connect(_frame_model)
	controls.add_child(reset)
	speed = SpinBox.new()
	speed.min_value = 0.1
	speed.max_value = 3.0
	speed.step = 0.1
	speed.value = 1.0
	speed.suffix = "×"
	speed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed.tooltip_text = "재생 속도"
	controls.add_child(speed)
	original_materials = CheckBox.new()
	original_materials.text = "원본 머티리얼"
	original_materials.tooltip_text = "기본은 자세를 보기 쉬운 무광 머티리얼입니다. 원본 리소스는 변경하지 않습니다."
	original_materials.toggled.connect(func(_enabled: bool): _apply_materials())
	add_child(original_materials)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status)
	var hint := Label.new()
	hint.text = "드래그: 회전 · 스크롤: 확대/축소"
	add_child(hint)
	_fill_clips()


func _build_world() -> void:
	world = Node3D.new()
	viewport.add_child(world)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.09, 0.11, 0.14)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color.WHITE
	settings.ambient_light_energy = 0.65
	environment.environment = settings
	world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, -35, 0)
	light.light_energy = 1.5
	world.add_child(light)
	camera = Camera3D.new()
	camera.fov = 45
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	world.add_child(camera)
	camera.current = true
	_update_camera()


func _fill_clips() -> void:
	var previous := ""
	if clip_menu.selected >= 0:
		previous = clip_menu.get_item_text(clip_menu.selected)
	clip_menu.clear()
	for clip in library.get_animation_list():
		clip_menu.add_item(String(clip))
		if String(clip) == previous:
			clip_menu.select(clip_menu.item_count - 1)
	clip_menu.disabled = clip_menu.item_count == 0


func update_models(paths: PackedStringArray) -> void:
	model_paths = paths
	if model_menu == null:
		return
	model_menu.clear()
	model_menu.add_item("모델 선택…")
	model_menu.set_item_metadata(0, "")
	var selected := 0
	for path in paths:
		model_menu.add_item(path.get_file())
		var index := model_menu.item_count - 1
		model_menu.set_item_metadata(index, path)
		model_menu.get_popup().set_item_tooltip(index, path)
		if path == preferred_model:
			selected = index
	model_menu.select(selected)
	if selected > 0:
		_load_model(preferred_model)
	else:
		_clear_model()
		_set_status("모델을 선택하세요." if paths.size() > 0 else "스켈레톤과 메시가 있는 모델이 없습니다.")


func _model_chosen(index: int) -> void:
	preferred_model = model_menu.get_item_metadata(index)
	model_selected.emit(preferred_model)
	_load_model(preferred_model)


func _clear_model() -> void:
	if is_instance_valid(retarget_bridge):
		retarget_bridge.free()
	retarget_bridge = null
	native_active = false
	if is_instance_valid(player):
		player.free()
	if is_instance_valid(model):
		model.free()
	player = null
	model = null
	skeleton = null
	timeline.set_value_no_signal(0)
	timeline.editable = false
	play_button.disabled = true


func _load_model(path: String) -> void:
	_clear_model()
	if path.is_empty():
		_set_status("모델을 선택하세요.")
		return
	var packed := ResourceLoader.load(path) as PackedScene
	if packed == null or not Catalog.is_model(packed):
		_set_status("스크립트 없는 모델과 스켈레톤 하나가 필요합니다.", "error")
		return
	var instance := packed.instantiate()
	if not instance is Node3D:
		instance.free()
		_set_status("Node3D 모델이 필요합니다.", "error")
		return
	model = instance as Node3D
	_prepare_nodes(model)
	_apply_materials()
	world.add_child(model)
	var skeletons := Binding.skeletons_in(model)
	if skeletons.size() != 1:
		_clear_model()
		_set_status("스켈레톤이 하나인 모델만 지원합니다.", "error")
		return
	skeleton = skeletons[0]
	player = AnimationPlayer.new()
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	world.add_child(player)
	player.root_node = player.get_path_to(model)
	_bind_library()
	_frame_model()


func _prepare_nodes(node: Node) -> void:
	node.process_mode = Node.PROCESS_MODE_DISABLED
	if node is MeshInstance3D:
		node.set_meta("_motion_preview_material", node.material_override)
	for child in node.get_children():
		# 미리보기의 재생과 렌더링을 플러그인이 제어하도록 원본 제어 노드를 제거한다.
		if (child is AnimationMixer or child is CollisionObject3D or child is Camera3D
			or child is AudioStreamPlayer or child is AudioStreamPlayer3D or child is SkeletonModifier3D):
			child.free()
		else:
			_prepare_nodes(child)


func _apply_materials() -> void:
	if not is_instance_valid(model):
		return
	var clay := StandardMaterial3D.new()
	clay.albedo_color = Color(0.55, 0.65, 0.75)
	clay.roughness = 0.85
	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	if model is MeshInstance3D:
		meshes.append(model)
	for mesh in meshes:
		mesh.material_override = mesh.get_meta("_motion_preview_material", null) if original_materials.button_pressed else clay


func _bind_library() -> void:
	player.stop(true)
	if player.has_animation_library(&"preview"):
		player.remove_animation_library(&"preview")
	if is_instance_valid(retarget_bridge):
		retarget_bridge.free()
	retarget_bridge = null
	var result := Binding.bind(library, skeleton, model, source_skeleton, Binding.Mapping.import_map(library.resource_path), Binding.Mapping.import_map(preferred_model))
	retarget_bridge = result.bridge
	native_clips = result.native_clips
	binding_errors = result.errors
	binding_warnings = result.warnings
	player.add_animation_library(&"preview", result.library)
	_play_clip()


func _play_clip() -> void:
	play_button.disabled = true
	timeline.editable = false
	if not is_instance_valid(player):
		return
	player.stop(true)
	native_active = false
	if is_instance_valid(retarget_bridge):
		retarget_bridge.reset()
	skeleton.reset_bone_poses()
	if clip_menu.item_count == 0:
		_set_status("라이브러리에 모션이 없습니다.")
		return
	var clip := clip_menu.get_item_text(clip_menu.selected)
	if binding_errors.has(clip):
		_set_status(binding_errors[clip], "error")
		return
	var key := StringName("preview/" + clip)
	if not player.has_animation(key):
		return
	native_active = native_clips.has(clip)
	player.play(key)
	player.advance(0.0)
	_update_retarget()
	timeline.max_value = maxf(player.current_animation_length, 0.001)
	timeline.set_value_no_signal(0.0)
	timeline.editable = true
	playing = true
	play_button.text = "일시정지"
	play_button.disabled = false
	_set_status(binding_warnings[clip], "warning") if binding_warnings.has(clip) else _set_status("%.2f초 · 미리보기 반복 재생" % player.current_animation_length)


func _process(delta: float) -> void:
	if not is_instance_valid(player) or play_button.disabled or not is_visible_in_tree():
		return
	if playing:
		player.advance(delta * speed.value)
		_update_retarget()
		timeline.set_value_no_signal(player.current_animation_position)


func _toggle_play() -> void:
	playing = not playing
	play_button.text = "일시정지" if playing else "재생"


func _seek(time: float) -> void:
	if not is_instance_valid(player) or play_button.disabled:
		return
	playing = false
	play_button.text = "재생"
	player.seek(time, true)
	_update_retarget()


func _library_changed() -> void:
	_fill_clips()
	_load_source_skeleton()
	if is_instance_valid(player):
		_bind_library()


func _clips_changed(_name: StringName) -> void:
	_library_changed()


func _clips_renamed(_old: StringName, _new: StringName) -> void:
	_library_changed()


func _frame_model() -> void:
	auto_frame = true
	if not is_instance_valid(model):
		return
	# 자동 선택은 레이아웃 전에 발생할 수 있으므로 표시 영역이 있어야 구도를 계산한다.
	if view_container.size.x <= 0 or view_container.size.y <= 0:
		return
	var bounds := AABB()
	var found := false
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null or mesh.mesh.get_surface_count() == 0:
			continue
		var box: AABB = mesh.global_transform * mesh.get_aabb()
		bounds = bounds.merge(box) if found else box
		found = true
	if not found:
		return
	target = bounds.get_center()
	var aspect := view_container.size.x / view_container.size.y
	var span := maxf(bounds.size.y, bounds.size.x / maxf(aspect, 0.1))
	distance = maxf(span / (2.0 * tan(deg_to_rad(camera.fov) * 0.5)) * 1.15 + bounds.size.z * 0.5, 0.1)
	orbit = Vector2(0.0, 0.12)
	_update_camera()


func _update_camera() -> void:
	var direction := Vector3(sin(orbit.x) * cos(orbit.y), sin(orbit.y), cos(orbit.x) * cos(orbit.y))
	camera.position = target + direction * distance
	camera.near = maxf(distance * 0.001, 0.001)
	camera.far = maxf(distance * 100, 100.0)
	camera.look_at(target, Vector3.UP)


func _view_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			auto_frame = false
			distance *= 0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1
			distance = clampf(distance, 0.01, 10000.0)
			_update_camera()
	if event is InputEventMouseMotion and dragging:
		auto_frame = false
		orbit.x -= event.relative.x * 0.01
		orbit.y = clampf(orbit.y + event.relative.y * 0.01, -1.3, 1.3)
		_update_camera()
	view_container.accept_event()


func _resize_view() -> void:
	# 컨테이너와 SubViewport의 크기가 반영된 다음 초기 구도를 보정한다.
	_reframe_after_resize.call_deferred()


func _reframe_after_resize() -> void:
	if is_instance_valid(camera) and auto_frame:
		_frame_model()


func _set_status(message: String, severity: String = "info") -> void:
	status.text = message
	status.remove_theme_color_override("font_color")
	if severity == "error":
		status.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	elif severity == "warning":
		status.add_theme_color_override("font_color", Color(1.0, 0.78, 0.3))


func _load_source_skeleton() -> void:
	if is_instance_valid(source_model):
		source_model.free()
	source_skeleton = null
	source_model = Binding.source_scene(library)
	if source_model != null:
		var skeletons := Binding.skeletons_in(source_model)
		if skeletons.size() == 1:
			source_skeleton = skeletons[0]


# 재생·시간 이동 직후 원본 골격 복사본에 적용된 자세를 엔진 보정에 넘긴다.
# 일시정지 상태의 seek()에서도 호출하며, 완료 후 화면 모델 갱신은 bridge가 담당한다.
func _update_retarget() -> void:
	if native_active and is_instance_valid(retarget_bridge):
		retarget_bridge.update()
