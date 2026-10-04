"""플러그인 폴더만 담은 설치용 ZIP을 생성합니다."""

import argparse
import configparser
from pathlib import Path
import re
import zipfile


def main() -> None:
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=root / "output",
                        help="ZIP을 저장할 폴더 (기본: 저장소의 output)")
    args = parser.parse_args()
    name = "motion_preview"
    source = root / "addons" / name
    config = configparser.ConfigParser()
    config.read(source / "plugin.cfg", encoding="utf-8")
    version = config["plugin"]["version"].strip('"')
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._-]*", version):
        parser.error("plugin.cfg의 버전을 파일명으로 사용할 수 없습니다.")
    files = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if any(part.startswith(".") or part == "__pycache__" for part in relative.parts):
            continue
        if path.is_symlink():
            parser.error("플러그인 폴더의 심볼릭 링크는 배포할 수 없습니다.")
        if path.is_file() and path.suffix not in (".pyc", ".tmp"):
            files.append((path, f"{name}/{relative.as_posix()}"))
    if not (source / "LICENSE").exists():
        files.append((root / "LICENSE", f"{name}/LICENSE"))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / ".gdignore").touch(exist_ok=True)
    archive = args.output_dir / f"{name}-{version}.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path, entry in files:
            bundle.write(path, entry)
    print(f"생성: {archive}")


if __name__ == "__main__":
    main()
