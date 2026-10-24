@tool
extends EditorProperty

var host
var enabled_toggle: CheckBox
var apply_button: Button
var restore_button: Button


func _init() -> void:
	var column := VBoxContainer.new()
	add_child(column)
	var row := HBoxContainer.new()
	column.add_child(row)
	enabled_toggle = CheckBox.new()
	enabled_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enabled_toggle.tooltip_text = "FBX를 AnimationLibrary로 임포트·재임포트하면 Import Rest as RESET을 true로 맞춥니다. 기존 파일 일괄 처리는 버튼으로 실행합니다."
	enabled_toggle.toggled.connect(func(value: bool): emit_changed(get_edited_property(), value))
	row.add_child(enabled_toggle)
	add_focusable(enabled_toggle)
	apply_button = Button.new()
	apply_button.text = "기존 모션 FBX에 적용"
	apply_button.tooltip_text = "프로젝트의 FBX AnimationLibrary에 RESET 저장을 켜고 재임포트합니다. 모델과 다른 임포트 설정은 유지합니다."
	apply_button.pressed.connect(func():
		if is_instance_valid(host):
			host.apply_reset_to_existing(get_window()))
	row.add_child(apply_button)
	add_focusable(apply_button)
	restore_button = Button.new()
	restore_button.text = "적용 전 설정 복원"
	restore_button.tooltip_text = "자동 적용을 끄고 애드온이 기록한 Import Rest as RESET 변경분만 복원·재임포트합니다. 다른 임포트 옵션은 유지합니다."
	restore_button.pressed.connect(func():
		if is_instance_valid(host):
			host.restore_reset_imports(get_window()))
	column.add_child(restore_button)
	add_focusable(restore_button)


func _update_property() -> void:
	enabled_toggle.set_pressed_no_signal(bool(get_edited_object().get(get_edited_property())))


func _set_read_only(value: bool) -> void:
	enabled_toggle.disabled = value
	apply_button.disabled = value
	restore_button.disabled = value
