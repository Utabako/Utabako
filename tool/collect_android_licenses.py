#!/usr/bin/env python3
"""按 Gradle 导出的固定版本收集 Android 依赖许可与原始源码通知。"""

from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import urllib.request
import xml.etree.ElementTree as ET
from zipfile import ZipFile

from build_libbox import OUTPUT, SPEC

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".dart_tool/release-sources/android"
NS = {"m": "http://maven.apache.org/POM/4.0.0"}


@dataclass(frozen=True)
class Module:
    group: str
    name: str
    version: str


@dataclass(frozen=True)
class AndroidSourceManifest:
    notices_sha256: str
    files: dict[str, str]


def download(url: str, path: Path) -> None:
    if path.exists():
        return
    with urllib.request.urlopen(url, timeout=60) as response:
        content = response.read()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def collect(module: Module) -> str:
    coordinate = f"{module.group}:{module.name}:{module.version}"
    if module.group == "io.flutter":
        return f"{coordinate}\nFlutter / Dart / engine 版权及完整许可见 Flutter 自动生成的 NOTICES.Z 和应用内 Flutter 许可条目。\n"
    base = ("https://dl.google.com/dl/android/maven2" if module.group.startswith("androidx.") else "https://repo.maven.apache.org/maven2")
    relative = f"{module.group.replace('.', '/')}/{module.name}/{module.version}/{module.name}-{module.version}"
    local = CACHE / module.group / module.name / module.version
    pom = local / "module.pom"
    download(f"{base}/{relative}.pom", pom)
    tree = ET.fromstring(pom.read_bytes())
    packaging = tree.findtext("m:packaging", "jar", NS)
    declarations = tree.findall("m:licenses/m:license", NS)
    while not declarations:
        parent = tree.find("m:parent", NS)
        if parent is None:
            break
        parent_module = Module(
            parent.findtext("m:groupId", "", NS),
            parent.findtext("m:artifactId", "", NS),
            parent.findtext("m:version", "", NS),
        )
        parent_relative = f"{parent_module.group.replace('.', '/')}/{parent_module.name}/{parent_module.version}/{parent_module.name}-{parent_module.version}.pom"
        parent_pom = CACHE / parent_module.group / parent_module.name / parent_module.version / "module.pom"
        download(f"{base}/{parent_relative}", parent_pom)
        tree = ET.fromstring(parent_pom.read_bytes())
        declarations = tree.findall("m:licenses/m:license", NS)
    if not declarations or any("Apache" not in item.findtext("m:name", "", NS) for item in declarations):
        raise ValueError(f"需人工核对非 Apache-2.0 或缺失的许可声明：{coordinate}")
    license_lines = [f"{item.findtext('m:name', '', NS)} — {item.findtext('m:url', '', NS)}" for item in declarations]
    sections = [coordinate, f"源码/元数据：{base}/{relative}", *license_lines]
    if packaging != "pom":
        sources = local / "sources.jar"
        download(f"{base}/{relative}-sources.jar", sources)
        with ZipFile(sources) as archive:
            if archive.testzip() is not None:
                raise ValueError(f"损坏的源码归档：{coordinate}")
            for name in sorted(archive.namelist()):
                filename = Path(name).name.lower()
                if not name.endswith("/") and filename.startswith(("license", "notice", "copying", "copyright", "authors")):
                    sections.extend((f"--- {name} ---", archive.read(name).decode("utf-8")))
    return "\n".join(sections) + "\n"


def main() -> None:
    modules = [Module(**item) for item in json.loads((ROOT / "build/app/reports/release-dependencies.json").read_text())]
    with ThreadPoolExecutor(max_workers=6) as pool:
        entries = list(pool.map(collect, modules))
    apache = CACHE / "Apache-2.0.txt"
    download("https://www.apache.org/licenses/LICENSE-2.0.txt", apache)
    sdk = Path(os.environ.get("ANDROID_HOME", "/usr/lib/android-sdk"))
    ndk_root = sdk / "ndk" / SPEC.ndk_version
    if f"Pkg.Revision = {SPEC.ndk_version}" not in (ndk_root / "source.properties").read_text().splitlines():
        raise ValueError("当前 NDK 与固定构建规格不一致")
    ndk = ndk_root / "toolchains/llvm/prebuilt/linux-x86_64"
    cpp = ndk / "sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
    bundled_cpp = OUTPUT / "jniLibs/arm64-v8a/libc++_shared.so"
    if hashlib.sha256(cpp.read_bytes()).digest() != hashlib.sha256(bundled_cpp.read_bytes()).digest():
        raise ValueError("当前 NDK 的 libc++ 与随包副本不同，不能沿用其 NOTICE")
    notices = "Android releaseRuntimeClasspath（android-arm64）\n\n" + "\n".join(entries)
    notices += "\nApache License 2.0（上述声明适用）\n\n" + apache.read_text()
    notices += f"\n\nAndroid NDK r{SPEC.ndk_version.split('.')[0]} / libc++ runtime\n与 NDK {SPEC.ndk_version} arm64 副本 SHA-256 一致；以下保留工具链原始 NOTICE。\n\n"
    notices += (ndk / "NOTICE").read_text()
    destination = ROOT / "licenses/android.txt"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(notices)
    (CACHE / "modules.json").write_text(json.dumps([{"group": item.group, "name": item.name, "version": item.version} for item in modules], indent=2) + "\n")
    manifest = AndroidSourceManifest(
        notices_sha256=hashlib.sha256(destination.read_bytes()).hexdigest(),
        files={
            path.relative_to(CACHE).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(CACHE.rglob("*"))
            if path.is_file() and path.name != "manifest.json"
        },
    )
    (CACHE / "manifest.json").write_text(json.dumps(asdict(manifest), indent=2) + "\n")
    print(f"已收集 {len(modules)} 个 Android 模块及匹配 NDK 的完整通知：{destination.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
