"""플러그인 폴더만 복사한 임시 Godot 프로젝트에서 에디터 통합을 검사합니다."""

from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile


def main() -> None:
    project = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", nargs="?", default="godot")
    parser.add_argument("--render", action="store_true", help="실제 에디터 렌더링과 미리보기 PNG 검사")
    args = parser.parse_args()
    engine = args.engine
    log_path = project / "output/motion_preview_checks" / ("rendered_editor.log" if args.render else "portable_editor.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    # 검사 결과는 로컬에서만 생성하고 Godot 임포트 대상에서도 제외한다.
    (project / "output/.gdignore").touch(exist_ok=True)
    outputs = []
    with tempfile.TemporaryDirectory(prefix="motion-preview-") as temporary:
        target = Path(temporary)
        shutil.copytree(project / "addons/motion_preview", target / "addons/motion_preview")
        probe = target / "addons/preview_probe"
        probe.mkdir()
        shutil.copyfile(project / "tests/motion_preview_editor_probe.gd", probe / "probe.gd")
        (probe / "plugin.cfg").write_text(
            '[plugin]\nname="Preview probe"\ndescription="임시 통합 검사"\n'
            'author="Test"\nversion="1"\nscript="probe.gd"\n', encoding="utf-8")
        (target / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Preview Portability Check"\n'
            'config/features=PackedStringArray("4.7", "Forward Plus")\n'
            '[editor_plugins]\nenabled=PackedStringArray('
            '"res://addons/motion_preview/plugin.cfg", '
            '"res://addons/preview_probe/plugin.cfg")\n', encoding="utf-8")
        commands = [
            [engine, "--headless", "--path", str(target), "--script", str(project / "tests/motion_preview_fixture.gd")],
            [engine, *([] if args.render else ["--headless"]), "--path", str(target), "--editor",
             *(["--", "--capture-dir", str(log_path.parent)] if args.render else [])],
        ]
        for command in commands:
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=45)
            except subprocess.TimeoutExpired as error:
                output = (error.stdout or b"").decode("utf-8", errors="replace") + (error.stderr or b"").decode("utf-8", errors="replace")
                outputs.append(output)
                log_path.write_text("\n".join(outputs), encoding="utf-8")
                print(output)
                raise SystemExit("에디터 검사 제한 시간(45초)을 초과했습니다.") from error
            output = result.stdout + result.stderr
            outputs.append(output)
            log_path.write_text("\n".join(outputs), encoding="utf-8")
            if result.returncode or "ERROR:" in output or "WARNING:" in output:
                print(output)
                raise SystemExit(result.returncode or 1)
        expected = 18 if args.render else 15
        marker = f"PORTABLE_EDITOR_COMPLETE checks={expected} failures=0"
        if marker not in outputs[-1]:
            print(outputs[-1])
            raise SystemExit("에디터 완료 표식이 없습니다.")
        print(marker)
        print(f"로그: {log_path}")


if __name__ == "__main__":
    main()
