@tool
extends VBoxContainer

const PerformanceLog = preload("performance_log.gd")

const Catalog = preload("model_catalog.gd")
const Binding = preload("motion_binding.gd")
const Bounds = preload("preview_bounds.gd")

signal model_selected(path: String)
signal refresh_requested
signal motions_changed
signal motion_changed(motion: StringName)
signal time_changed(seconds: float, duration: float)
signal playback_changed(is_playing: bool)
signal target_changed
signal load_failed(message: String)

var _loaded_model_stamp := Vector2i.ZERO
var _loaded_model_path := ""
var _framing_bounds := AABB()
var _has_framing_bounds := false
var _import_retarget_driver: Skeleton3D
var _prepared := false
var _animation_root: Node
var _pose_updated := Callable()
var _selected_motion: StringName = &""
var _looping := true
var _rate := 1.0
var _available := false
var _selectors_visible := true
var _use_original_materials := false

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
var playing := false
var orbit := Vector2(0.0, 0.12)
var distance := 3.0
var target := Vector3.ZERO
var dragging := false
var auto_frame := true


func _ready() -> void:
	if library == null:
		library = AnimationLibrary.new()
	_build_ui()
	_build_world()
	_connect_library()
	_load_source_skeleton()
	set_selectors_visible(_selectors_visible)
	set_original_materials(_use_original_materials)
	update_models(model_paths)


func _exit_tree() -> void:
	_disconnect_library()
	if is_instance_valid(source_model):
		source_model.free()
	source_model = null
	clear_preview()


func _connect_library() -> void:
	if library == null:
		return
	library.changed.connect(_library_changed)
	library.animation_added.connect(_clips_changed)
	library.animation_removed.connect(_clips_changed)
	library.animation_renamed.connect(_clips_renamed)
	library.animation_changed.connect(_clips_changed)


func _disconnect_library() -> void:
	if is_instance_valid(library) and library.changed.is_connected(_library_changed):
		library.changed.disconnect(_library_changed)
		library.animation_added.disconnect(_clips_changed)
		library.animation_removed.disconnect(_clips_changed)
		library.animation_renamed.disconnect(_clips_renamed)
		library.animation_changed.disconnect(_clips_changed)


## May be called before ready. Null means an empty library.
func set_animation_library(value: AnimationLibrary) -> void:
	_disconnect_library()
	library = value if value != null else AnimationLibrary.new()
	if not is_node_ready():
		return
	if _prepared:
		clear_preview()
	_connect_library()
	_library_changed()


func get_motions() -> PackedStringArray:
	var result := PackedStringArray()
	if clip_menu != null:
		for index in clip_menu.item_count:
			result.append(clip_menu.get_item_text(index))
	elif library != null:
		for key in library.get_animation_list():
			result.append(String(key))
	return result


func get_selected_motion() -> StringName:
	return _selected_motion


func select_motion(key: StringName) -> bool:
	if clip_menu == null or String(key) not in get_motions():
		_fail("등록되지 않은 모션: " + String(key))
		return false
	clip_menu.select(get_motions().find(String(key)))
	_play_clip()
	return _available


func has_motion() -> bool:
	return _available and is_instance_valid(player)


func get_duration() -> float:
	return player.get_animation(_player_key()).length if has_motion() else 0.0


func get_time() -> float:
	return player.current_animation_position if has_motion() else 0.0


func is_playing() -> bool:
	return playing and has_motion()


func play() -> void:
	if not has_motion():
		return
	if not _looping and get_time() >= get_duration():
		seek_time(0.0)
	_set_playing(true)


func pause() -> void:
	_set_playing(false)


func set_playback_speed(value: float) -> void:
	if not is_finite(value):
		return
	_rate = clampf(value, 0.1, 3.0)
	if speed != null:
		speed.set_value_no_signal(_rate)


func get_playback_speed() -> float:
	return _rate


func set_looping(value: bool) -> void:
	_looping = value
	if has_motion():
		player.get_animation(_player_key()).loop_mode = Animation.LOOP_LINEAR if value else Animation.LOOP_NONE


func is_looping() -> bool:
	return _looping


func seek_time(seconds: float) -> void:
	if not has_motion() or not is_finite(seconds):
		return
	pause()
	var clip := player.get_animation(_player_key())
	var loop := clip.loop_mode
	clip.loop_mode = Animation.LOOP_NONE
	player.seek(clampf(seconds, 0.0, get_duration()), true)
	clip.loop_mode = loop
	_update_retarget()
	_publish_time()


func reset_view() -> void:
	if is_node_ready():
		_frame_model()


func set_selectors_visible(value: bool) -> void:
	_selectors_visible = value
	if model_menu != null:
		model_menu.get_parent().visible = value
		clip_menu.visible = value


func set_original_materials(value: bool) -> void:
	_use_original_materials = value
	if original_materials != null:
		original_materials.set_pressed_no_signal(value)
		_apply_materials()


func load_model(path: String) -> bool:
	if not is_node_ready():
		_fail("모델 로드는 ready 이후에 호출하세요.")
		return false
	preferred_model = path
	_load_model(path)
	return is_instance_valid(model)


func clear_preview() -> void:
	_clear_model()
	if clip_menu != null:
		_fill_clips()
	motions_changed.emit()


## Takes ownership only on success. See API.md for the adapter safety contract.
func set_prepared_target(root: Node3D, animation_root: Node, libraries: Dictionary,
		pose_updated: Callable = Callable()) -> bool:
	if not is_node_ready() or not is_instance_valid(root) or root.is_queued_for_deletion() or root.get_parent() != null or root.is_inside_tree():
		_fail("ready 이후 분리된 미리보기 전용 Node3D가 필요합니다.")
		return false
	if not is_instance_valid(animation_root) or not (root == animation_root or root.is_ancestor_of(animation_root)):
		_fail("애니메이션 루트는 미리보기 대상 안에 있어야 합니다.")
		return false
	if not _validate_prepared_nodes(root):
		_fail("준비된 대상에서 스크립트·플레이어·충돌·카메라·오디오·보조 modifier를 제거하세요.")
		return false
	var copies := {}
	for library_name in libraries:
		if not library_name is StringName and not library_name is String:
			_fail("라이브러리 키는 StringName 또는 String이어야 합니다.")
			return false
		if not libraries[library_name] is AnimationLibrary:
			_fail("AnimationLibrary 리소스가 필요합니다.")
			return false
		var source: AnimationLibrary = libraries[library_name]
		if source == null or String(library_name).contains("/") or String(library_name).contains(":"):
			_fail("올바른 라이브러리 이름과 AnimationLibrary가 필요합니다.")
			return false
		var copy := AnimationLibrary.new()
		for key in source.get_animation_list():
			var clip := source.get_animation(key).duplicate(true) as Animation
			for track in range(clip.get_track_count() - 1, -1, -1):
				var path := clip.track_get_path(track)
				var destination := animation_root.get_node_or_null(NodePath(path.get_concatenated_names())) if not path.is_absolute() else null
				if not Binding._is_bone_track(clip, track):
					clip.remove_track(track)
				elif path.is_absolute() or not destination is Skeleton3D or not (destination == root or root.is_ancestor_of(destination)) or destination.find_bone(path.get_subname(0)) < 0:
					_fail("준비된 모션의 본 경로를 확인하세요: " + String(path))
					return false
			clip.loop_mode = Animation.LOOP_LINEAR if _looping else Animation.LOOP_NONE
			copy.add_animation(key, clip)
		copies[StringName(library_name)] = copy
	_clear_model()
	_prepared = true
	model = root
	_animation_root = animation_root
	_pose_updated = pose_updated
	_remember_materials(model)
	world.add_child(model)
	player = AnimationPlayer.new()
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	world.add_child(player)
	player.root_node = player.get_path_to(animation_root)
	for library_name in copies:
		player.add_animation_library(library_name, copies[library_name])
	_fill_clips()
	_apply_materials()
	_frame_model()
	target_changed.emit()
	_play_clip()
	return true


func _validate_prepared_nodes(node: Node) -> bool:
	if node.is_queued_for_deletion() or node.get_script() != null or node is AnimationMixer or node is CollisionObject3D or node is Camera3D or node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D or (node is SkeletonModifier3D and not node is RetargetModifier3D):
		return false
	for child in node.get_children():
		if not _validate_prepared_nodes(child):
			return false
	return true


func _remember_materials(node: Node) -> void:
	if node is MeshInstance3D:
		node.set_meta("_motion_preview_material", node.material_override)
	for child in node.get_children():
		_remember_materials(child)


func _player_key() -> StringName:
	return _selected_motion if _prepared else StringName("preview/" + String(_selected_motion))


func _set_playing(value: bool) -> void:
	var changed := playing != value
	playing = value
	if play_button != null:
		play_button.text = "일시정지" if value else "재생"
	if changed:
		playback_changed.emit(value)


func _publish_time() -> void:
	if timeline != null:
		timeline.set_value_no_signal(get_time())
	time_changed.emit(get_time(), get_duration())


func _fail(message: String) -> void:
	if status != null:
		_set_status(message, "error")
	load_failed.emit(message)


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
	view_container.custom_minimum_size = Vector2(0, 320)
	view_container.stretch = true
	view_container.mouse_filter = Control.MOUSE_FILTER_STOP
	view_container.gui_input.connect(_view_input)
	view_container.resized.connect(_resize_view)
	view_container.mouse_exited.connect(func(): dragging = false)
	add_child(view_container)
	viewport = SubViewport.new()
	viewport.size = Vector2i(320, 320)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
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
	speed.value = _rate
	speed.value_changed.connect(set_playback_speed)
	speed.suffix = "×"
	speed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed.tooltip_text = "재생 속도"
	controls.add_child(speed)
	original_materials = CheckBox.new()
	original_materials.text = "원본 머티리얼"
	original_materials.tooltip_text = "기본은 자세를 보기 쉬운 무광 머티리얼입니다. 원본 리소스는 변경하지 않습니다."
	original_materials.toggled.connect(set_original_materials)
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
	for clip in (player.get_animation_list() if _prepared and is_instance_valid(player) else library.get_animation_list()):
		if _prepared and clip == &"RESET":
			continue
		clip_menu.add_item(String(clip))
		if String(clip) == previous:
			clip_menu.select(clip_menu.item_count - 1)
	clip_menu.disabled = clip_menu.item_count == 0
	motions_changed.emit()


# Filesystem/manual refresh must replace live nodes even when only imported
# dependencies changed and the source file's timestamp stayed the same.
func refresh_models(paths: PackedStringArray) -> void:
	model_paths = paths
	if _prepared or not is_node_ready():
		return
	_load_source_skeleton()
	_loaded_model_path = ""
	update_models(paths)


func update_models(paths: PackedStringArray) -> void:
	model_paths = paths
	if _prepared:
		return
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
		if _loaded_model_path != preferred_model or not is_instance_valid(model) or _loaded_model_stamp != _model_stamp(preferred_model):
			_load_model(preferred_model)
	else:
		_clear_model()
		_set_status("모델을 선택하세요." if paths.size() > 0 else "스켈레톤과 메시가 있는 모델이 없습니다.")


func _model_chosen(index: int) -> void:
	preferred_model = model_menu.get_item_metadata(index)
	model_selected.emit(preferred_model)
	_load_model(preferred_model)


func _clear_model() -> void:
	_import_retarget_driver = null
	_loaded_model_path = ""
	_has_framing_bounds = false
	_available = false
	_set_playing(false)
	_selected_motion = &""
	_pose_updated = Callable()
	_animation_root = null
	_prepared = false
	if is_instance_valid(retarget_bridge):
		retarget_bridge.free()
	retarget_bridge = null
	native_active = false
	native_clips.clear()
	binding_errors.clear()
	binding_warnings.clear()
	if is_instance_valid(player):
		player.free()
	if is_instance_valid(model):
		model.free()
	player = null
	model = null
	skeleton = null
	if timeline != null:
		timeline.set_value_no_signal(0)
		timeline.editable = false
		play_button.disabled = true
	motion_changed.emit(&"")
	_publish_time()
	target_changed.emit()


func _model_stamp(path: String) -> Vector2i:
	return Vector2i(FileAccess.get_modified_time(path), FileAccess.get_modified_time(path + ".import") if FileAccess.file_exists(path + ".import") else 0)


func _load_model(path: String) -> void:
	var started := Time.get_ticks_usec()
	_load_model_impl(path)
	PerformanceLog.write("model + binding + framing: %.1f ms | %s" % [(Time.get_ticks_usec() - started) / 1000.0, path])


func _load_model_impl(path: String) -> void:
	_clear_model()
	_fill_clips()
	if path.is_empty():
		_set_status("모델을 선택하세요.")
		return
	if not Catalog.accepts_path(path):
		_fail("모델은 FBX 또는 GLB 파일을 선택하세요.")
		return
	if not ResourceLoader.exists(path, "PackedScene"):
		_fail("모델 씬을 읽을 수 없습니다: " + path)
		return
	var started := Time.get_ticks_usec()
	var packed := Catalog.load_preview_scene(path)
	_log_time("model resource load", started)
	if packed == null or not Catalog.is_model(packed):
		_fail("스크립트 없는 모델과 단일 골격 또는 연결된 리타게팅 골격이 필요합니다.")
		return
	started = Time.get_ticks_usec()
	var instance := packed.instantiate()
	_log_time("model instantiate", started)
	if not instance is Node3D:
		instance.free()
		_fail("Node3D 모델이 필요합니다.")
		return
	model = instance as Node3D
	_prepare_nodes(model)
	_apply_materials()
	world.add_child(model)
	var skeletons := Binding.skeletons_in(model)
	skeleton = Catalog.driving_skeleton(model)
	if skeleton == null:
		_clear_model()
		_fail("단일 골격 또는 연결된 리타게팅 골격이 필요합니다.")
		return
	if skeletons.size() == 2:
		_import_retarget_driver = skeleton
	_loaded_model_path = path
	_loaded_model_stamp = _model_stamp(path)
	player = AnimationPlayer.new()
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	world.add_child(player)
	player.root_node = player.get_path_to(model)
	started = Time.get_ticks_usec()
	_bind_library()
	_log_time("animation binding", started)
	started = Time.get_ticks_usec()
	_frame_model()
	_log_time("framing", started)
	target_changed.emit()


func _prepare_nodes(node: Node) -> void:
	if node is Skeleton3D:
		node.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	node.process_mode = Node.PROCESS_MODE_DISABLED
	if node is MeshInstance3D:
		node.set_meta("_motion_preview_material", node.material_override)
	for child in node.get_children():
		# 미리보기의 재생과 렌더링을 플러그인이 제어하도록 원본 제어 노드를 제거한다.
		if (child is AnimationMixer or child is CollisionObject3D or child is Camera3D
			or child is AudioStreamPlayer or child is AudioStreamPlayer3D or (child is SkeletonModifier3D and not child is RetargetModifier3D)):
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
	_available = false
	_set_playing(false)
	_selected_motion = &""
	play_button.disabled = true
	timeline.editable = false
	if not is_instance_valid(player):
		return
	player.stop(true)
	native_active = false
	if is_instance_valid(retarget_bridge):
		retarget_bridge.reset()
	if _prepared:
		for rig in Binding.skeletons_in(model):
			rig.reset_bone_poses()
	elif is_instance_valid(skeleton):
		skeleton.reset_bone_poses()
	if clip_menu.item_count == 0:
		_set_status("라이브러리에 모션이 없습니다.")
		motion_changed.emit(&"")
		_publish_time()
		return
	var clip := clip_menu.get_item_text(clip_menu.selected)
	if binding_errors.has(clip):
		_fail(binding_errors[clip])
		motion_changed.emit(&"")
		_publish_time()
		return
	_selected_motion = StringName(clip)
	var key := _player_key()
	if not player.has_animation(key):
		_selected_motion = &""
		return
	native_active = native_clips.has(clip)
	player.get_animation(key).loop_mode = Animation.LOOP_LINEAR if _looping else Animation.LOOP_NONE
	player.play(key)
	player.advance(0.0)
	_available = true
	_update_retarget()
	timeline.max_value = maxf(get_duration(), 0.001)
	timeline.editable = true
	play_button.disabled = false
	_set_playing(true)
	_set_status(binding_warnings[clip], "warning") if binding_warnings.has(clip) else _set_status("%.2f초 · 미리보기" % get_duration())
	motion_changed.emit(_selected_motion)
	_publish_time()


func _process(delta: float) -> void:
	if not has_motion() or not is_visible_in_tree():
		return
	if playing:
		var next := get_time() + delta * _rate
		player.advance(delta * _rate)
		if not _looping and next >= get_duration():
			player.seek(get_duration(), true)
			_set_playing(false)
		_update_retarget()
		_publish_time()


func _toggle_play() -> void:
	if is_playing():
		pause()
	else:
		play()


func _seek(time: float) -> void:
	seek_time(time)


func _library_changed() -> void:
	Binding.clear_caches()
	if _prepared:
		return
	_fill_clips()
	_load_source_skeleton()
	if is_instance_valid(player):
		_bind_library()


func _clips_changed(_name: StringName) -> void:
	_library_changed()


func _clips_renamed(_old: StringName, _new: StringName) -> void:
	_library_changed()


func _frame_model(reuse_bounds: bool = false) -> void:
	auto_frame = true
	if not is_instance_valid(model):
		return
	# 자동 선택은 레이아웃 전에 발생할 수 있으므로 표시 영역이 있어야 구도를 계산한다.
	if view_container.size.x <= 0 or view_container.size.y <= 0:
		return
	if not reuse_bounds or not _has_framing_bounds:
		var bounds := AABB()
		var found := false
		var meshes := model.find_children("*", "MeshInstance3D", true, false)
		if model is MeshInstance3D:
			meshes.append(model)
		for mesh in meshes:
			if mesh.mesh == null or mesh.mesh.get_surface_count() == 0:
				continue
			var box := Bounds.mesh_bounds(mesh)
			bounds = bounds.merge(box) if found else box
			found = true
		if not found:
			return
		_framing_bounds = bounds
		_has_framing_bounds = true
	var bounds := _framing_bounds
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
	# 인스펙터 폭에 맞춰 높이도 조절해 인간형 모델의 표시 영역을 정사각형으로 유지한다.
	if view_container.size.x > 0:
		view_container.custom_minimum_size.y = view_container.size.x
	# 컨테이너와 SubViewport의 크기가 반영된 다음 초기 구도를 보정한다.
	_reframe_after_resize.call_deferred()


func _reframe_after_resize() -> void:
	if is_instance_valid(camera) and auto_frame:
		_frame_model(true)


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
	source_model = Binding.source_scene(library, model_paths)
	if source_model != null:
		var skeletons := Binding.skeletons_in(source_model)
		if skeletons.size() == 1:
			source_skeleton = skeletons[0]


# 재생·시간 이동 직후 원본 골격 복사본에 적용된 자세를 엔진 보정에 넘긴다.
# 일시정지 상태의 seek()에서도 호출하며, 완료 후 화면 모델 갱신은 bridge가 담당한다.
func _update_retarget() -> void:
	if native_active and is_instance_valid(retarget_bridge):
		retarget_bridge.update()
	if is_instance_valid(_import_retarget_driver):
		_import_retarget_driver.advance(0.0)
	if _pose_updated.is_valid():
		_pose_updated.call()


func _log_time(stage: String, started: int) -> void:
	PerformanceLog.write("%s: %.1f ms" % [stage, (Time.get_ticks_usec() - started) / 1000.0])
