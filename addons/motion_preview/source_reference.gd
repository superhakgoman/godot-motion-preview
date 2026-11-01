@tool
extends RefCounted

## 모션의 RESET이 첫 프레임인 패키지는 제작자가 제공한 기준 모델을 명시합니다.
const SETTING := "addons/motion_preview/retarget/source_models"
const Catalog = preload("model_catalog.gd")
const Mapping = preload("humanoid_mapping.gd")
const Native = preload("native_retarget.gd")
const Log = preload("performance_log.gd")

static func register_setting() -> void:
	if not ProjectSettings.has_setting(SETTING):
		ProjectSettings.set_setting(SETTING, {})
	ProjectSettings.set_initial_value(SETTING, {})
	ProjectSettings.add_property_info({"name": SETTING, "type": TYPE_DICTIONARY})

static func configured_path(library: AnimationLibrary) -> String:
	var entries: Variant = ProjectSettings.get_setting(SETTING, {})
	if not entries is Dictionary: return ""
	var path := library.resource_path.get_slice("::", 0)
	var longest := ""
	var result := ""
	for prefix in entries:
		if not prefix is String or not entries[prefix] is String: continue
		if prefix.begins_with("res://") and prefix.ends_with("/") and prefix.trim_suffix("/") == prefix.simplify_path().trim_suffix("/") and path.begins_with(prefix) and prefix.length() > longest.length():
			longest = prefix
			result = entries[prefix]
	return result

static func normalized_import(library: AnimationLibrary) -> bool:
	var config := ConfigFile.new()
	if config.load(library.resource_path.get_slice("::", 0) + ".import") != OK: return false
	var sub: Variant = config.get_value("params", "_subresources", {})
	if not sub is Dictionary or not sub.get("nodes", {}) is Dictionary: return false
	for options in sub.get("nodes", {}).values():
		if options is Dictionary and options.get("retarget/bone_renamer/rename_bones", false):
			# 이미 표준화한 트랙에는 공급자 원본 좌표계의 rest를 덮어쓰지 않습니다.
			return true
	return false

static func from_config(library: AnimationLibrary, imported: Skeleton3D) -> Skeleton3D:
	var path := configured_path(library)
	if path.is_empty() or normalized_import(library): return null
	if not preload("import_policy.gd")._local_project_path(path) or not Catalog.accepts_path(path):
		imported.set_meta("_motion_preview_reference_error", "모션 기준 모델은 프로젝트 내부의 실제 FBX·GLB 파일이어야 합니다.")
		return null
	var packed := ResourceLoader.load(path) as PackedScene
	if packed == null or not Catalog.is_model(packed):
		imported.set_meta("_motion_preview_reference_error", "안전한 모션 기준 모델을 읽을 수 없습니다: " + path)
		return null
	var scene := packed.instantiate()
	var reference := Catalog.driving_skeleton(scene)
	var result := copy_matching(imported, reference) if reference != null else null
	scene.free()
	if result == null:
		imported.set_meta("_motion_preview_reference_error", "모션과 기준 모델의 본 이름·역할·부모 계층이 맞지 않습니다: " + path)
		return null
	result.set_meta("_motion_preview_reference_path", path)
	Log.diagnostic("source_reference", {"library": library.resource_path, "model": path})
	return result

## 같은 제작 리그만 허용합니다. 선택한 출력 모델을 원본 모션의 기준으로 추측하지 않습니다.
static func copy_matching(imported: Skeleton3D, reference: Skeleton3D) -> Skeleton3D:
	if imported == null or reference == null: return null
	var roles := Mapping.for_skeleton(imported)
	if roles.get("Hips", "").is_empty() or roles.get("Head", "").is_empty(): return null
	var reference_roles := Mapping.for_skeleton(reference)
	for role in roles:
		var name: String = roles[role]
		if reference_roles.get(role, "") != name: return null
		var a := imported.get_bone_parent(imported.find_bone(name))
		var b := reference.get_bone_parent(reference.find_bone(name))
		while a >= 0 and imported.get_bone_name(a) not in roles.values(): a = imported.get_bone_parent(a)
		while b >= 0 and reference.get_bone_name(b) not in roles.values(): b = reference.get_bone_parent(b)
		if (imported.get_bone_name(a) if a >= 0 else "") != (reference.get_bone_name(b) if b >= 0 else ""): return null
	var copy := Skeleton3D.new()
	copy.transform = Native.skeleton_space(reference)
	copy.motion_scale = imported.motion_scale
	var signature := {}
	var globals: Array[Transform3D] = []
	for index in reference.get_bone_count():
		var name := String(reference.get_bone_name(index))
		copy.add_bone(name)
		globals.append(reference.get_bone_global_rest(index))
		if name in roles.values():
			var parent := reference.get_bone_parent(index)
			signature[name] = {"rest":reference.get_bone_rest(index), "parent":String(reference.get_bone_name(parent)) if parent >= 0 else ""}
	# Root는 메시 변형 본의 bind 축과 별도로 내보내는 모션 기준 노드일 수 있습니다.
	# 그 노드의 임포트 공간을 보존하고 나머지 본의 모델 공간 bind 자세를 다시 로컬로 분해합니다.
	var root_name: String = roles.get("Root", "")
	if not root_name.is_empty():
		var index := reference.find_bone(root_name)
		globals[index] = copy.transform.affine_inverse() * Native.skeleton_space(imported) * imported.get_bone_global_rest(imported.find_bone(root_name))
	for index in reference.get_bone_count():
		var parent := reference.get_bone_parent(index)
		copy.set_bone_parent(index,parent)
		copy.set_bone_rest(index,globals[parent].affine_inverse()*globals[index] if parent >= 0 else globals[index])
	copy.reset_bone_poses()
	copy.set_meta("_motion_preview_rest_mode", "reference_model")
	copy.set_meta("_motion_preview_direct_signature", signature)
	copy.set_meta("_motion_preview_reference_space", copy.transform)
	return copy

## 명시한 기준 모델과 같은 리그에는 원래 키를 직접 재생합니다. 이름만 같은 모델은 허용하지 않습니다.
static func matches_target(source: Skeleton3D, target: Skeleton3D) -> bool:
	if source == null or not source.has_meta("_motion_preview_direct_signature"): return false
	if not source.get_meta("_motion_preview_reference_space").is_equal_approx(Native.skeleton_space(target)): return false
	var signature: Dictionary = source.get_meta("_motion_preview_direct_signature")
	for name in signature:
		var index := target.find_bone(name)
		if index < 0 or not signature[name].rest.is_equal_approx(target.get_bone_rest(index)): return false
		var parent := target.get_bone_parent(index)
		if signature[name].parent != (String(target.get_bone_name(parent)) if parent >= 0 else ""): return false
	return not signature.is_empty()
