@tool
extends RefCounted

# SkeletonProfileHumanoid는 관절 역할 목록, BoneMap은 특정 모델의 역할→본 대응표다.
# humanoid_aliases.json은 역할별 소문자 별칭, 접두어·좌우·손가락 표기를 정의한다.
# role()은 이 규칙으로 본 이름을 정규화하고, 아래 함수들은 계층·위치로 대응을 보완한다.
# 규칙은 메모리에 캐시하며 플러그인을 다시 켜면 reload_rules()로 파일을 다시 읽는다.
static var rules: Dictionary = _load_rules()


static func _load_rules() -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://addons/motion_preview/humanoid_aliases.json"))
	if not data is Dictionary or data.get("version") != 1:
		push_error("Motion Preview: humanoid_aliases.json 형식이 올바르지 않습니다.")
		return {}
	for key in ["strip_tokens", "strip_prefixes", "separators", "sided_roles", "finger_segments", "thumb_segments"]:
		if not data.get(key) is Array:
			push_error("Motion Preview: 본 이름 규칙의 배열이 없습니다: " + key)
			return {}
	for key in ["sides", "aliases", "fingers"]:
		if not data.get(key) is Dictionary:
			push_error("Motion Preview: 본 이름 규칙의 사전이 없습니다: " + key)
			return {}
	return data


static func reload_rules() -> void:
	rules = _load_rules()


static func role(bone: String) -> String:
	if rules.is_empty():
		return ""
	var name := bone.to_lower().get_slice(":", bone.count(":"))
	for token in rules.strip_tokens:
		name = name.replace(token, "")
	for prefix in rules.strip_prefixes:
		if name.begins_with(prefix):
			name = name.trim_prefix(prefix)
			break
	var side := ""
	for key in rules.sides:
		var options: Dictionary = rules.sides[key]
		var matches := false
		for word in options.words:
			matches = matches or name.contains(word)
		for prefix in options.prefixes:
			matches = matches or name.begins_with(prefix)
		for infix in options.infixes:
			matches = matches or name.contains(infix)
		for suffix in options.suffixes:
			matches = matches or name.ends_with(suffix)
		if matches:
			if not side.is_empty():
				return "" # 좌우 표기가 겹치면 빈 대응을 반환한다.
			side = key
	if not side.is_empty():
		var options: Dictionary = rules.sides[side]
		for word in options.words:
			name = name.replace(word, "")
		for prefix in options.prefixes:
			name = name.trim_prefix(prefix)
		for infix in options.infixes:
			name = name.replace(infix, "_")
		for suffix in options.suffixes:
			name = name.trim_suffix(suffix)
	for token in rules.separators:
		name = name.replace(token, "")
	var result := ""
	for key in rules.aliases:
		if name in rules.aliases[key]:
			if not result.is_empty():
				return "" # 역할이 중복된 별칭은 빈 대응을 반환한다.
			result = key
	if not result.is_empty():
		return side + result if result in rules.sided_roles and not side.is_empty() else ("" if result in rules.sided_roles else result)
	for finger in rules.fingers:
		for alias in rules.fingers[finger]:
			if name.begins_with(alias) and not side.is_empty():
				var number := name.trim_prefix(alias).trim_prefix("0")
				if number in ["1", "2", "3"]:
					var segments: Array = rules.thumb_segments if finger == "Thumb" else rules.finger_segments
					return side + finger + String(segments[int(number) - 1])
	return ""


static func unique_roles(names: PackedStringArray) -> Dictionary:
	var result := {}
	for bone in names:
		var key := role(bone)
		if key.is_empty():
			continue
		if result.has(key):
			result[key] = ""
		else:
			result[key] = bone
	return result


# 고급 임포트 설정에 저장된 BoneMap을 먼저 사용한다.
static func import_map(path: String) -> BoneMap:
	var config := ConfigFile.new()
	if config.load(path.get_slice("::", 0) + ".import") != OK:
		return null
	var resources: Dictionary = config.get_value("params", "_subresources", {})
	var result: BoneMap
	for options in resources.get("nodes", {}).values():
		var map: Variant = options.get("retarget/bone_map")
		if map is BoneMap and map.profile is SkeletonProfileHumanoid:
			if result != null:
				return null # 복수 매핑은 단일 골격용 대응에서 제외한다.
			result = map
	return result


# 대응 우선순위는 저장된 BoneMap → 정확한 표준 이름 → 일반 별칭 → 구조 추론이다.
# 사용자 매핑과 이미 식별된 관절을 유지한 채, 양 끝이 알려진 관절 사이만 보완한다.
static func for_skeleton(skeleton: Skeleton3D, map: BoneMap = null) -> Dictionary:
	var names := PackedStringArray()
	for index in skeleton.get_bone_count():
		names.append(skeleton.get_bone_name(index))
	var result := unique_roles(names)
	# Spine → Spine1 → Spine2는 번호 없는 본부터, spine_01 → 02 → 03은 1부터 시작한다.
	# 실제 골격의 연결 순서로 몸통 본을 대응시킨다.
	var hips: String = result.get("Hips", "")
	var head: String = result.get("Head", "")
	if not hips.is_empty() and not head.is_empty():
		var chain := PackedStringArray()
		var index := skeleton.get_bone_parent(skeleton.find_bone(head))
		var hip_index := skeleton.find_bone(hips)
		while index >= 0 and index != hip_index:
			var name := skeleton.get_bone_name(index)
			if name.to_lower().contains("spine") or name.to_lower().contains("chest"):
				chain.append(name)
			index = skeleton.get_bone_parent(index)
		if index == hip_index and chain.size() > 0 and chain.size() <= 3:
			chain.reverse()
			for key in ["Spine", "Chest", "UpperChest"]:
				result.erase(key)
			for item in chain.size():
				result[["Spine", "Chest", "UpperChest"][item]] = chain[item]
	var profile := SkeletonProfileHumanoid.new()
	var valid := {}
	for index in profile.bone_size:
		var key := String(profile.get_bone_name(index))
		var configured := String(map.get_skeleton_bone_name(key)) if map != null else ""
		if not configured.is_empty() and skeleton.find_bone(configured) >= 0:
			valid[key] = configured
		elif skeleton.find_bone(key) >= 0:
			valid[key] = key
		elif result.get(key, "") != "":
			valid[key] = result[key]
	# 같은 본을 지정한 중복 역할은 대응표에서 제거한다.
	var seen := {}
	for key in valid.keys():
		var bone: String = valid[key]
		if seen.has(bone):
			valid.erase(seen[bone])
			valid.erase(key)
		else:
			seen[bone] = key
	_infer_chains(skeleton, valid)
	return valid


# 부분 골격의 미리보기를 위해 식별된 관절 사이의 조상 관계를 검사한다.
# 빠진 중간 관절은 건너뛰고 가장 가까운 식별 관절을 기준으로 검증한다.
static func validate(skeleton: Skeleton3D, roles: Dictionary) -> String:
	var profile := SkeletonProfileHumanoid.new()
	if roles.is_empty():
		return "대응 가능한 인간형 본을 식별하지 못했습니다"
	# 프로필의 부모 관계와 실제 골격의 조상 관계를 검사한다.
	for index in profile.bone_size:
		var role := String(profile.get_bone_name(index))
		if not roles.has(role):
			continue
		var parent := String(profile.get_bone_parent(index))
		while not parent.is_empty() and not roles.has(parent):
			var parent_index := profile.find_bone(parent)
			parent = String(profile.get_bone_parent(parent_index)) if parent_index >= 0 else ""
		if parent.is_empty():
			continue
		var bone := skeleton.find_bone(roles[role])
		var ancestor := skeleton.find_bone(roles[parent])
		bone = skeleton.get_bone_parent(bone)
		while bone >= 0 and bone != ancestor:
			bone = skeleton.get_bone_parent(bone)
		if bone < 0:
			return "인간형 본 계층이 맞지 않습니다: %s → %s" % [parent, role]
	return ""


# 이미 식별한 어깨·손 또는 골반·발 사이의 경로에서 중간 본의 역할을 추론한다.
# 경로의 본 수, 기존 대응과의 일관성, 기준 위치의 순서를 확인해 대응을 확정한다.
static func _infer_chains(skeleton: Skeleton3D, roles: Dictionary) -> void:
	for side in ["Left", "Right"]:
		for chain in [[side + "Shoulder", side + "UpperArm", side + "LowerArm", side + "Hand"], ["Hips", side + "UpperLeg", side + "LowerLeg", side + "Foot"]]:
			for start in range(chain.size() - 2):
				for finish in range(start + 2, chain.size()):
					if not roles.has(chain[start]) or not roles.has(chain[finish]):
						continue
					var path: Array[int] = []
					var ancestor := skeleton.find_bone(roles[chain[start]])
					var bone := skeleton.find_bone(roles[chain[finish]])
					bone = skeleton.get_bone_parent(bone)
					while bone >= 0 and bone != ancestor:
						path.push_front(bone)
						bone = skeleton.get_bone_parent(bone)
					if bone != ancestor or path.size() != finish - start - 1:
						continue
					var first := skeleton.get_bone_global_rest(ancestor).origin
					var last := skeleton.get_bone_global_rest(skeleton.find_bone(roles[chain[finish]])).origin
					var direction := last - first
					if direction.length_squared() < 0.000001:
						continue
					var previous := 0.0
					var valid := true
					for index in path.size():
						var name := skeleton.get_bone_name(path[index])
						var key: String = chain[start + index + 1]
						if (roles.has(key) and roles[key] != name) or (not roles.has(key) and name in roles.values()):
							valid = false
						var position := skeleton.get_bone_global_rest(path[index]).origin - first
						var progress := position.dot(direction) / direction.length_squared()
						# 순방향의 서로 다른 위치와 경로 주변의 범위를 만족하는 후보를 채택한다.
						if progress <= previous + 0.001 or progress >= 0.999 or position.distance_to(direction * progress) > direction.length() * 0.35:
							valid = false
						previous = progress
					if valid:
						for index in path.size():
							roles[chain[start + index + 1]] = skeleton.get_bone_name(path[index])


# 프로필의 required 표시로 누락된 주요 관절에 대한 정확도 경고를 생성한다.
# 원본과 대상 중 한쪽에만 있는 주요 관절은 그 아래 부위의 동작에도 영향을 줄 수 있다.
static func missing_body_roles(source: Dictionary, target: Dictionary) -> PackedStringArray:
	var result := PackedStringArray()
	var profile := SkeletonProfileHumanoid.new()
	for index in profile.bone_size:
		var key := String(profile.get_bone_name(index))
		if profile.is_required(index) and source.has(key) != target.has(key):
			result.append(key)
	return result
