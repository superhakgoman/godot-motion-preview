@tool
extends EditorInspectorPlugin

const Preview = preload("preview_control.gd")

var host
var previews: Array[WeakRef] = []


func _can_handle(object: Object) -> bool:
	return object is AnimationLibrary


func _parse_begin(object: Object) -> void:
	var preview := Preview.new()
	preview.library = object as AnimationLibrary
	preview.model_paths = host.model_paths
	preview.preferred_model = host.selected_model
	preview.model_selected.connect(host.remember_model)
	preview.refresh_requested.connect(host.refresh_models)
	host.models_changed.connect(preview.update_models)
	previews = previews.filter(func(reference: WeakRef): return reference.get_ref() != null)
	previews.append(weakref(preview))
	add_custom_control(preview)


func clear_previews() -> void:
	for reference in previews:
		var control: Variant = reference.get_ref()
		if control != null:
			control.queue_free()
	previews.clear()
