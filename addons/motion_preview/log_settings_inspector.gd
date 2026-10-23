@tool
extends EditorInspectorPlugin

const PerformanceLog = preload("performance_log.gd")
const LogProperty = preload("log_settings_property.gd")


func _can_handle(object: Object) -> bool:
	# Project Settings uses a section filter that strips the current section prefix.
	return object == ProjectSettings or object.get_class() == "SectionedInspectorFilter"


func _parse_property(_object: Object, type: Variant.Type, name: String,
		_hint: PropertyHint, _hint_string: String, _usage: int, _wide: bool) -> bool:
	if type != TYPE_BOOL or not (name == PerformanceLog.SETTING or PerformanceLog.SETTING.ends_with("/" + name)):
		return false
	add_property_editor(name, LogProperty.new())
	return true
