"""실제 FBX를 임시 프로젝트에 복사해 RESET 임포트 정책을 검사합니다."""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fbx", type=Path, help="골격 노드와 모션이 포함된 테스트용 FBX")
    parser.add_argument("--engine", default="godot")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    output = project / "output/motion_preview_checks/import_policy.log"
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="motion-import-policy-") as temporary:
        target = Path(temporary)
        shutil.copytree(project / "addons/motion_preview", target / "addons/motion_preview")
        probe = target / "addons/import_probe"
        probe.mkdir()
        shutil.copyfile(project / "tests/motion_preview_import_probe.gd", probe / "probe.gd")
        (probe / "plugin.cfg").write_text('[plugin]\nname="Import probe"\ndescription="Test"\nauthor="Test"\nversion="1"\nscript="probe.gd"\n')
        (target / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Motion Import Check"\n[editor_plugins]\nenabled=PackedStringArray("res://addons/motion_preview/plugin.cfg", "res://addons/import_probe/plugin.cfg")\n')
        for name, importer, kind in [("legacy", "animation_library", "AnimationLibrary"), ("model", "scene", "PackedScene")]:
            shutil.copyfile(args.fbx, target / (name + ".FBX"))
            (target / (name + ".FBX.import")).write_text(f'[remap]\nimporter="{importer}"\ntype="{kind}"\n[params]\nnodes/import_as_skeleton_bones=true\nanimation/import_rest_as_RESET=false\nanimation/fps=24\nfbx/importer=0\n')
        command = [args.engine, "--headless", "--editor", "--path", str(target), "--quit-after", "2400", "--log-file", str(target / "editor.log")]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        except subprocess.TimeoutExpired as error:
            output.write_bytes((error.stdout or b"") + (error.stderr or b""))
            raise SystemExit("임포트 정책 검사 시간 초과; 로그를 확인하세요.")
        text = result.stdout + result.stderr
        output.write_text(text)
        for line in text.splitlines():
            if "IMPORT_POLICY " in line or "IMPORT_POLICY_COMPLETE" in line or "SCRIPT ERROR" in line:
                print(line)
        if result.returncode or "SCRIPT ERROR" in text or "failures=0" not in text or "IMPORT_POLICY_COMPLETE" not in text:
            raise SystemExit(result.returncode or 1)
        print(f"로그: {output}")


if __name__ == "__main__":
    main()
