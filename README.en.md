# Motion Preview

[한국어](README.md) | **English**

## Introduction

A Godot editor plugin that previews an animation library (`AnimationLibrary`) on a 3D model in the Inspector. Browse motions without running your game or creating a separate preview scene. Targets Godot 4.7 and later.

## Installing and using it in a game project

### Installation

1. Download the plugin from this repository's Releases and extract the archive.
2. Place the `motion_preview` folder inside your game project's `addons/` folder. The resulting path must be `addons/motion_preview/plugin.cfg`.
3. In Godot, open **Project → Project Settings → Plugins** and enable **Motion Preview**.
4. Wait for Godot to finish importing your models and animations.

Disable the plugin or close the editor before updating or removing it. To update, replace the existing plugin folder with the new version.

### Usage

The plugin's controls currently use Korean labels; their meanings are provided below.

1. **Single-click** an FBX imported as an `AnimationLibrary`, or a `.tres` / `.res` animation library, in the FileSystem dock. Double-clicking an FBX opens Godot's import settings instead.
2. Choose a model from **모델 선택…** (Select model…) in the Inspector preview.
3. The first animation plays on a loop. If the library contains multiple animations, use the clip menu to switch between them.

- Use **일시정지 / 재생** (Pause / Play), the timeline slider, and playback speeds from **0.1× to 3×** to inspect motions. Moving the timeline slider pauses playback.
- Drag to rotate the view and scroll to zoom. **시점 초기화** (Reset view) returns to a view that fits the whole model.
- Enable **원본 머티리얼** (Original materials) to display the model's materials instead of the matte materials used to make poses easier to see.
- The last model selection is retained when switching libraries or reopening the editor.
- The model list refreshes after models are added, moved, or reimported. Use **↻** to refresh it manually.

### Compatible models and animations

Models are discovered throughout the project. Imported FBX and GLB models, along with `.tscn` / `.scn` scenes, appear in the list if they have **no attached scripts, exactly one Skeleton3D, and an actual mesh**. Scenes with game scripts are excluded. To preview such a character, you must save a separate scene containing its appearance without scripts. No dedicated asset folder is required.

Use models and motions intended for the same skeleton and rest pose. If a required bone is missing, the animation does not play and the missing bones are listed. Matching bone names alone is insufficient: automatic retargeting for different proportions, rest poses, or bone hierarchies is not provided.

Bone position, rotation, and scale animations are played. Method calls, audio, and general property tracks are not played. Root motion can move a model outside the view; an in-place playback option is not provided. Original models, animations, and the scene currently being edited are left unchanged.

## Modifying the source

Clone the repository, then follow these steps.

1. Open `project.godot` in Godot. The plugin is enabled by default.
2. Modify the GDScript files under `addons/motion_preview/`. Add your own models and animations to the development project to inspect the behavior in the editor.
3. Run the regression checks below to verify that existing behavior still works.
4. Use the packaging script below to create a ZIP, then install it in your game project.

### Regression checks for existing behavior

These tests check whether adding a new feature has broken existing behavior. They generate a simple model and animation in a temporary project, so external assets are not required.

- Selecting a library creates the preview, and a model can be discovered and selected.
- Moving the timeline slider changes the model's bone pose.
- Model selection persists when switching libraries and reactivating the plugin.
- Initial framing and resizing keep the model in view, while preserving a view adjusted by the user.

Prepare the Godot executable and Python 3, then run these commands from the repository root. If `godot` is not on PATH, replace it with the executable's path.

```sh
godot --headless --path . --editor --quit
python3 tests/check_motion_preview_portability.py godot
```

Failed checks produce a nonzero exit code. The log is written to `output/motion_preview_checks/portable_editor.log`.

If you change the visual display, also run the following command in an environment with graphics support.

```sh
python3 tests/check_motion_preview_portability.py godot --render
```

Open `initial.png`, `reset.png`, and `narrow.png` in the same output folder to inspect the actual rendered views.

These tests do not verify the correctness of new features. Add checks for new functionality, and update the relevant checks if you intentionally change existing behavior. Compatibility with different model and animation formats and skeletons must be checked separately.

### Installing your modified plugin

Run this command with Python 3 from the repository root.

```sh
python3 release.py
```

This creates `output/motion_preview-<version>.zip`. The ZIP contains only the plugin contents; the version is read from `addons/motion_preview/plugin.cfg`.

Extract the ZIP and move the resulting `motion_preview` folder into your chosen Godot project's `addons/` folder. Check that the resulting path is `addons/motion_preview/plugin.cfg`, then enable the plugin. Disable the plugin or close the editor before replacing an existing installation.
