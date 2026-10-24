# Motion Preview embedding API — 1.2.0

Godot 4.7+. Preload `res://addons/motion_preview/preview_control.gd` and embed the resulting VBoxContainer in an editor panel. Composition is recommended; subclassing is optional. Camera, lighting, orbit/zoom, framing, playback and scrubbing use the same implementation as the Inspector. Fields such as `player`, `timeline`, `clip_menu`, `model` and underscore-prefixed methods are implementation details, not the public embedding contract.

## Public methods

| Method | Contract |
|---|---|
| `set_animation_library(AnimationLibrary)` | Configure before ready or replace afterward. Null creates an empty library. Observes library changes. Rebinds an existing safe model. When leaving prepared mode, releases that target; load a safe model afterward. |
| `load_model(path: String) -> bool` | After ready, load an FBX or GLB using the safe catalog policy and bind the configured library. Other file formats are rejected. Single skeletons and connected imported driver/RetargetModifier/deformation pairs are supported. Replaces/releases the previous target, even on failure. Does not broaden the Inspector policy. |
| `set_prepared_target(root: Node3D, animation_root: Node, libraries: Dictionary, pose_updated: Callable = Callable()) -> bool` | After ready, accept an adapter-prepared instance with registered motion paths. Detailed ownership and safety contract below. No automatic remapping or retargeting. |
| `clear_preview()` | Release the target/player/bridge/callback, stop playback, clear selection/time. Configured safe library and preferences remain. Safe repeatedly and before ready. |
| `get_motions() -> PackedStringArray` | Safe mode: configured library clip names. Prepared mode: full AnimationPlayer keys such as `rpg/attack`; default library keys have no prefix. `RESET` and namespaced `/RESET` entries are omitted from playable menus. |
| `select_motion(key: StringName) -> bool` | Start the selected clip at zero. Both UI selection and this method autoplay. Unknown key returns false, emits failure and preserves the prior selection. A known but unbindable safe clip stops playback and clears selection. |
| `get_selected_motion() -> StringName`, `has_motion() -> bool` | Empty name/false when no playable selection. A listed clip can fail binding. |
| `play()`, `pause()`, `is_playing() -> bool` | Resume/pause. Play at the end of a nonlooping clip restarts at zero. Playback advancement is suspended while the control is hidden. |
| `get_duration() -> float`, `get_time() -> float` | Actual clip seconds, independent of speed; zero when unavailable. Duration is not a gameplay duration override. |
| `seek_time(seconds: float)` | Clamp to [0, duration], pause, apply pose, publish time. A looping clip can be inspected at its exact final pose. Nonfinite input is ignored. |
| `set_playback_speed(value: float)`, `get_playback_speed() -> float` | Clamp to 0.1–3.0, synchronize with UI. Nonfinite input is ignored. Can configure before ready. |
| `set_looping(bool)`, `is_looping() -> bool` | Default true; edits preview copies only. Nonlooping playback pauses at the exact end. |
| `set_selectors_visible(bool)` | Show/hide model and clip selectors. Can configure before ready. Playback, timeline, view and material controls remain. |
| `set_original_materials(bool)` | Default false (clay). Can configure before ready. Changes instance material overrides, never source mesh/material resources. |
| `reset_view()` | Frame the target with the shared camera code. Layout/resize can complete framing on a subsequent frame. |

The existing Inspector hooks `model_selected(path)`, `refresh_requested`, `update_models(paths)` and pre-ready `model_paths`/`preferred_model` configuration remain supported. For new consumers use `set_animation_library` rather than assigning `library` after ready. Calling `update_models` in prepared mode updates the discovery cache without replacing the prepared target.

## Signals

- `motions_changed()` — reread the list; can occur more than once during replacement.
- `motion_changed(motion: StringName)` — selected clip or empty name when cleared/unavailable.
- `time_changed(seconds: float, duration: float)` — initial pose, seek, advancing playback, or reset to zero. Modifier rendering can finish on a subsequent engine frame.
- `playback_changed(is_playing: bool)` — playing flag transitions, including seek, clear and nonlooping completion.
- `target_changed()` — target released or installed. Replacement can emit both stages.
- `load_failed(message: String)` — invalid target/model/selection or safe binding failure; also shown in the built-in status label when ready.

Signals are synchronous; use them to read state/update external controls. Defer operations that replace targets or libraries until the signal handler returns. They are notifications, not cancellable loading transactions. Calls are on the main thread. Empty getters and playback calls are safe before ready. Target loading requires ready. Removing and reattaching the same control is not supported; create a new control after teardown.

## Prepared target contract

This extension exists because a game may use scripts, multiple skeletons and an existing RetargetModifier3D hierarchy. The safe catalog loader intentionally does not accept that scene directly. The game adapter must create and sanitize a disposable appearance instance **before it enters the scene tree**. Do not pass the live game actor or edited scene.

Pass a detached, nonqueued Node3D root and an animation root within its subtree. Pass a dictionary of library names to AnimationLibrary resources; use `&""` for the default library. The adapter can extract these resources and the animation root from its original player, then remove that player before handing the appearance over. There is no need to preserve or access the internal preview player.

On success the control owns the root and frees it on replacement, clear or teardown. The caller may keep nonowning references for overlays/modifier callbacks, but must not free, reparent or structurally mutate the installed target. Attach game-specific overlay children before handoff. On validation failure ownership stays with the caller and the previous preview remains intact. `load_model` intentionally has the older clear-first behavior.

The boundary validates that no scripts, AnimationMixer/AnimationPlayer/AnimationTree, CollisionObject3D, camera, audio player or non-retarget SkeletonModifier3D remains. Engine RetargetModifier3D nodes and multiple Skeleton3D nodes are preserved. The adapter is trusted: it remains responsible for stripping gameplay, auxiliary physics, timers, external callbacks and any other side effects. This validation is not a general scene security sandbox. Never instantiate unknown tool scripts just to sanitize them afterward.

Each library/Animation is copied. Existing relative bone transform track paths are retained and must resolve to a bone on a Skeleton3D inside the supplied root, relative to `animation_root`. Bad bone paths reject the handoff atomically. Method/audio/property/animation playback and other non-bone tracks are stripped from the copies. No automatic Binding.bind call, source skeleton reconstruction, additional bridge, or second retargeting occurs. Existing engine modifiers are the adapter's responsibility. Clips with no bone tracks remain usable for timing only. Mesh/material/Skin and original Animation/AnimationLibrary resources are never edited by the control.

Prepared libraries are snapshots and are not subscribed to source edits. Recreate a prepared target when source registrations, paths or clips change. Configuration of the safe library remains separate and is restored by `clear_preview`/`load_model`.

The optional `pose_updated` callable runs after the player's initial pose, seek and advance, before `time_changed`. For rigs configured for manual modifier processing, call the prepared drive skeleton's `advance(0.0)` there. Engine modifier processing/rendered deformation may settle on subsequent frames; do not assume `time_changed` means rendering is finished. Automatic modifiers can instead use their normal engine update. The callable is discarded before the owned root is freed. It must not retain/mutate the source game actor or source resources.

## Composition example

```gdscript
const Preview = preload("res://addons/motion_preview/preview_control.gd")
var preview = Preview.new()

func _ready() -> void:
    preview.set_selectors_visible(false)
    preview.set_original_materials(true)
    add_child(preview)
    preview.time_changed.connect(_on_time_changed)
    preview.load_failed.connect(func(message): error_label.text = message)

func install_appearance(appearance: Node3D, animation_root: Node,
        registered: Dictionary, drive_rig: Skeleton3D) -> bool:
    # All arguments are prepared by YOUR game adapter before entering the tree.
    # Example registered = {&"rpg": original_player.get_animation_library(&"rpg")}
    # Remove that original player and game scripts before this call.
    var update_pose := func(): drive_rig.advance(0.0)
    if not preview.set_prepared_target(appearance, animation_root, registered, update_pose):
        appearance.free() # failure leaves ownership here
        return false
    motions.clear()
    for key in preview.get_motions():
        motions.add_item(key)
    preview.select_motion(&"rpg/attack")
    preview.pause()
    return true

func seek_phase(phase: float) -> void:
    if preview.has_motion():
        preview.seek_time(clampf(phase, 0.0, 1.0) * preview.get_duration())

func _on_time_changed(seconds: float, duration: float) -> void:
    timing_bar.cursor = seconds / duration if duration > 0.0 else 0.0
    timing_bar.queue_redraw()
```

For a safe standalone model use `set_animation_library(source)`, add the control, then `load_model("res://my_model.glb")`. Select with the bare clip key. The library is rebound using the existing safe bone mapping/retargeting code.

## Migrating a 1.1.2 adapter

Replace overrides of `_load_model`, `_play_clip`, `_clear_model`, `_update_retarget` with adapter preparation plus `set_prepared_target`. Preserve the adapter's engine RetargetModifier and remove original mixers. Collect all original library namespaces, retain the animation root within the detached appearance, then hand over the root. For an initially paused timing editor call `pause()` after handoff/selection.

Replace `player.get_animation_list()` with `get_motions()`, menu manipulation with `select_motion()`, `play_button.disabled` with `not has_motion()`, `playing` with `is_playing()`, `timeline.max_value` with `get_duration()`, `timeline.value` with `get_time()`/`seek_time()`, and UI hiding/material field access with the public setters. Replace per-frame UI polling with `time_changed`, `motion_changed` and `playback_changed`. Game-specific timing markers, resource properties, visual extraction paths and XZ range overlays stay in the consuming adapter/editor.

The plugin does not implement combat, gameplay events, marker persistence, UndoRedo or a universal skill schema. Consumer migrations and tests against production characters/motions belong to the consuming project; the embedding API was validated with generated fixtures.

## Imported RESET references (1.3.0)

FBX AnimationLibrary imports can automatically enable `animation/import_rest_as_RESET`. The opt-out project setting is `addons/motion_preview/import/auto_import_rest_as_reset` (default true). Existing files are changed only through the explicit bulk button or a subsequent import/reimport. Disabling the setting stops future enforcement and does not undo existing per-file settings.

The scene import plugin stores immutable skeleton topology, coordinate transform and motion scale on the imported RESET animation. The safe preview reconstructs a separate skeleton and uses RESET keys for its rest transforms. It does not play that RESET on the destination model or replace a consumer's default RESET. Resources created before installation need the bulk reimport to acquire this metadata. An imported RESET alone does not identify or reconstruct the original author's missing bind data.

Automatic reference-model discovery and first-node-pose retarget fallback were removed. Missing reliable reference data is reported instead of inferring a rest from another project model. Explicit source skeletons passed to internal binding tests and original bind data present in source files remain supported.

Import-option recovery stores the original presence/value of the specific option before its first change. The restore button disables enforcement, restores only recorded options and reimports. Originally true files and unrelated later settings are preserved; failed entries remain available for retry. Recovery does not roll back game scenes, code, or changes made before the recovery record existed.

Import-policy writes are limited to canonical project-local resource paths. Symlinked sources, sidecars and ancestor directories are excluded. RESET metadata is data-only and is validated before skeleton reconstruction. Project resources and prepared adapters remain trusted input; these checks do not make a general-purpose asset sandbox.
