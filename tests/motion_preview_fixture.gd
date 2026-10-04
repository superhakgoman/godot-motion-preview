extends SceneTree
func _initialize():
 var model = Node3D.new()
 model.name = "TestModel"
 var skeleton = Skeleton3D.new()
 skeleton.name = "Skeleton"
 model.add_child(skeleton)
 skeleton.owner = model
 skeleton.add_bone("Hip")
 var mesh = MeshInstance3D.new()
 mesh.name = "Body"
 mesh.mesh = BoxMesh.new()
 mesh.mesh.size = Vector3(5, 2, 0.6)
 model.add_child(mesh)
 mesh.owner = model
 var scene = PackedScene.new()
 scene.pack(model)
 ResourceSaver.save(scene, "res://fixture_model.tscn")
 model.free()
 var clip = Animation.new()
 clip.length = 1
 var track = clip.add_track(Animation.TYPE_ROTATION_3D)
 clip.track_set_path(track, NodePath("Skeleton:Hip"))
 clip.rotation_track_insert_key(track, 0, Quaternion.IDENTITY)
 clip.rotation_track_insert_key(track, 1, Quaternion(Vector3.UP, 1))
 var library = AnimationLibrary.new()
 library.add_animation("turn", clip)
 ResourceSaver.save(library, "res://fixture_motion.tres")
 quit()
