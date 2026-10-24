@tool
extends EditorScenePostImportPlugin


func _post_process(scene: Node) -> void:
	# Never create/replace a user-authored RESET. The engine owns its creation.
	if not get_option_value("animation/import_rest_as_RESET"):
		return
	for player in scene.find_children("*", "AnimationPlayer", true, false):
		for name in player.get_animation_library_list():
			var library: AnimationLibrary = player.get_animation_library(name)
			if library.has_animation(&"RESET"):
				preload("rest_pose.gd").capture(player, library.get_animation(&"RESET"))
