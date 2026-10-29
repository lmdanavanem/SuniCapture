"""Build Debian and archive distributions using the Linux system runtime."""
from pathlib import Path
import argparse
import hashlib
import os
import platform
import py_compile
import re
import shutil
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
DEPENDENCIES = [
    "python3 (>= 3.10)", "python3-gi", "python3-gi-cairo", "python3-cairo", "python3-gst-1.0",
    "gir1.2-gtk-3.0", "gir1.2-gstreamer-1.0", "gir1.2-gst-plugins-base-1.0",
    "gstreamer1.0-plugins-base", "gstreamer1.0-plugins-good", "gstreamer1.0-plugins-ugly", "gstreamer1.0-plugins-bad",
    "gstreamer1.0-libav", "gstreamer1.0-gtk3", "gstreamer1.0-pipewire", "ffmpeg",
    "pulseaudio-utils", "libx11-6", "fonts-dejavu-core",
]


def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf8", newline="\n")
    path.chmod(0o755 if executable else 0o644)


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o644)


def populate(target):
    source = ROOT / "src/SuniCapture.Linux"
    copy(source / "launch.py", target / "launch.py")
    for file in sorted((source / "sunicapture").iterdir()):
        if file.suffix in (".py", ".json"):
            copy(file, target / "sunicapture" / file.name)
    copy(ROOT / "src/SuniCapture/Localization/strings.json", target / "resources/strings.json")
    for name in ("sunicapture-icon.png", "sunicapture-logo.png"):
        copy(ROOT / "assets/Brand" / name, target / "resources/assets/Brand" / name)
        copy(ROOT / "assets/Brand" / name, target / "assets/Brand" / name)
    for name in ("README.md", "README.fr.md", "README.en.md", "CHANGELOG.md", "THIRD-PARTY-NOTICES.md"):
        copy(ROOT / name, target / name)
    for file in sorted((ROOT / "docs").rglob("*")):
        if file.is_file() and (file.suffix == ".png" or file.name in (
                "linux.md", "development.md", "design.md", "video-engine.md", "verification-0.4.0.md", "verification-0.4.0.json") or file.parent.name == "releases"):
            copy(file, target / "docs" / file.relative_to(ROOT / "docs"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine().lower() not in ("x86_64", "amd64"):
        raise SystemExit("Build Linux x64 distributions on Linux x86_64.")
    for command in ("dpkg-deb", "desktop-file-validate"):
        if not shutil.which(command):
            raise SystemExit("Missing build component: " + command)
    version = ET.parse(ROOT / "src/SuniCapture/SuniCapture.csproj").findtext("PropertyGroup/Version")
    linux_version = re.search(r'VERSION\s*=\s*"([^"]+)"', (ROOT / "src/SuniCapture.Linux/sunicapture/__init__.py").read_text()).group(1)
    if version != linux_version or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("Windows and Linux versions must match.")
    subprocess.run(["desktop-file-validate", str(ROOT / "packaging/linux/ch.suniworks.SuniCapture.desktop")], check=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sunicapture-package-") as directory:
        temp = Path(directory)
        portable = temp / ("SuniCapture-" + version + "-linux-x64")
        populate(portable / "app")
        for name in ("README.md", "README.fr.md", "README.en.md", "CHANGELOG.md", "THIRD-PARTY-NOTICES.md", "docs", "assets"):
            shutil.move(str(portable / "app" / name), str(portable / name))
        write(portable / "sunicapture", '#!/bin/sh\nset -eu\nAPP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec /usr/bin/python3 "$APP_DIR/app/launch.py" "$@"\n', True)
        copy(ROOT / "packaging/linux/ch.suniworks.SuniCapture.desktop", portable / "ch.suniworks.SuniCapture.desktop")
        for index, source in enumerate(portable.rglob("*.py")):
            py_compile.compile(str(source), cfile=str(temp / (str(index) + ".pyc")), doraise=True)
        archive = output / (portable.name + ".tar.xz")
        def normalized(info):
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            return info
        with tarfile.open(archive, "w:xz") as bundle:
            bundle.add(portable, arcname=portable.name, filter=normalized)
        debian = temp / "debian"
        populate(debian / "usr/lib/sunicapture")
        write(debian / "usr/bin/sunicapture", '#!/bin/sh\nexec /usr/bin/python3 /usr/lib/sunicapture/launch.py "$@"\n', True)
        copy(ROOT / "packaging/linux/ch.suniworks.SuniCapture.desktop", debian / "usr/share/applications/ch.suniworks.SuniCapture.desktop")
        copy(ROOT / "assets/Brand/sunicapture-icon.png", debian / "usr/share/pixmaps/ch.suniworks.SuniCapture.png")
        copy(ROOT / "THIRD-PARTY-NOTICES.md", debian / "usr/share/doc/sunicapture/copyright")
        installed_size = sum(file.stat().st_size for file in (debian / "usr").rglob("*") if file.is_file()) // 1024
        control = ("Package: sunicapture\nVersion: " + version + "\nSection: graphics\nPriority: optional\nArchitecture: amd64\n"
            "Maintainer: lmdanavanem <287339505+lmdanavanem@users.noreply.github.com>\nInstalled-Size: " + str(installed_size) + "\n"
            "Depends: " + ", ".join(DEPENDENCIES) + "\n"
            "Recommends: xdg-desktop-portal, xdg-desktop-portal-gtk, pipewire\n"
            "Homepage: https://github.com/lmdanavanem/SuniCapture\n"
            "Description: Local screenshots, annotations and MP4 screen recording\n"
            " Capture regions, displays and windows, annotate images, export to image\n"
            " formats or PDF, and record H.264 MP4 video in a local library.\n"
            " Includes French and English interfaces with light and dark themes.\n")
        write(debian / "DEBIAN/control", control)
        for directory in (path for path in debian.rglob("*") if path.is_dir()):
            directory.chmod(0o755)
        package = output / ("SuniCapture-" + version + "-linux-amd64.deb")
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", str(debian), str(package)], check=True)
    checksums = "".join(hashlib.sha256(file.read_bytes()).hexdigest() + "  " + file.name + "\n" for file in (package, archive))
    write(output / "SHA256SUMS-linux.txt", checksums)
    print(checksums, end="")


if __name__ == "__main__":
    main()
