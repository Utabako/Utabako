#!/usr/bin/env python3
"""从固定 sing-box 源码构建 Android arm64 Libbox。"""

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".dart_tool/libbox"
SOURCE = CACHE / "source"
OUTPUT = ROOT / "build/app/libbox"


@dataclass(frozen=True)
class BuildSpec:
    repository: str
    commit: str
    version: str
    upstream_commit: str
    source_h1: str
    go_zt_commit: str
    go_version: str
    gomobile_version: str
    ndk_version: str
    android_api: int
    tags: list[str]


@dataclass(frozen=True)
class LibboxProvenance(BuildSpec):
    aar_sha256: str
    native_sha256: str


SPEC = BuildSpec(**json.loads((ROOT / "tool/libbox.json").read_text()))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--jdk", type=Path, required=True)
    args = parser.parse_args()
    sdk = args.sdk.resolve()
    jdk = args.jdk.resolve()
    ndk = sdk / "ndk" / SPEC.ndk_version
    tools = CACHE / "bin"
    temporary = CACHE / "tmp"
    for directory in (OUTPUT, tools, temporary):
        directory.mkdir(parents=True, exist_ok=True)
    environment = os.environ | {
        "GOTOOLCHAIN": "local",
        "GOWORK": "off",
        "GOFLAGS": "-mod=readonly",
        "GOPATH": str(CACHE / "go"),
        "GOMODCACHE": str(CACHE / "go/pkg/mod"),
        "GOCACHE": str(CACHE / "go-build"),
        "GOBIN": str(tools),
        "TMPDIR": str(temporary),
        "GOTMPDIR": str(temporary),
        "ANDROID_HOME": str(sdk),
        "ANDROID_SDK_ROOT": str(sdk),
        "ANDROID_NDK_HOME": str(ndk),
        "JAVA_HOME": str(jdk),
        "CGO_ENABLED": "1",
        "PATH": os.pathsep.join((str(tools), str(jdk / "bin"), os.environ["PATH"])),
    }
    go_version = subprocess.check_output(["go", "version"], env=environment, text=True).split()[2]
    if go_version != SPEC.go_version:
        raise ValueError(f"Libbox requires {SPEC.go_version}, found {go_version}")
    java = subprocess.run([str(jdk / "bin/java"), "-XshowSettings:properties", "-version"], env=environment, capture_output=True, text=True, check=True)
    if "java.specification.version = 21" not in java.stderr:
        raise ValueError("Libbox requires JDK 21")

    if not SOURCE.exists():
        subprocess.run(["git", "init", str(SOURCE)], check=True, env=environment)
    for commit in (SPEC.commit, SPEC.upstream_commit):
        present = subprocess.run(["git", "-C", str(SOURCE), "cat-file", "-e", f"{commit}^{{commit}}"], capture_output=True)
        if present.returncode != 0:
            subprocess.run(["git", "-C", str(SOURCE), "fetch", "--depth=1", SPEC.repository, commit], check=True, env=environment)
    subprocess.run(["git", "-C", str(SOURCE), "checkout", "--detach", SPEC.commit], check=True, env=environment)
    if subprocess.check_output(["git", "-C", str(SOURCE), "status", "--porcelain"], text=True).strip():
        raise ValueError("Libbox source checkout has local changes")
    for tool in ("gomobile", "gobind"):
        subprocess.run(["go", "install", f"github.com/sagernet/gomobile/cmd/{tool}@{SPEC.gomobile_version}"], cwd=SOURCE, env=environment, check=True)

    flags = f"-X github.com/sagernet/sing-box/constant.Version={SPEC.version} -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -s -w -buildid= -checklinkname=0"
    command = [str(tools / "gomobile"), "bind", "-v", "-o", str(OUTPUT / "libbox.aar"), "-target", "android/arm64", "-androidapi", str(SPEC.android_api), "-libname=box", "-trimpath", "-buildvcs=false", "-ldflags", flags, "-tags", ",".join(SPEC.tags), "./experimental/libbox"]
    subprocess.run(command, cwd=SOURCE, env=environment, check=True)
    with ZipFile(OUTPUT / "libbox.aar") as archive:
        native = archive.read("jni/arm64-v8a/libbox.so")
    native_file = OUTPUT / "libbox.so"
    native_file.write_bytes(native)
    buildinfo = subprocess.check_output(["go", "version", "-m", str(native_file)], env=environment, text=True)
    buildinfo = f"libbox.so: {SPEC.go_version}\n" + buildinfo.split("\n", 1)[1]
    (OUTPUT / "libbox.buildinfo.txt").write_text(buildinfo)
    cpp = ndk / "toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
    cpp_output = OUTPUT / "jniLibs/arm64-v8a/libc++_shared.so"
    cpp_output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(cpp, cpp_output)
    with (OUTPUT / "libbox.aar").open("rb") as stream:
        aar_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    provenance = LibboxProvenance(
        **asdict(SPEC),
        aar_sha256=aar_hash,
        native_sha256=hashlib.sha256(native).hexdigest(),
    )
    (OUTPUT / "libbox.aar.provenance.json").write_text(json.dumps(asdict(provenance), indent=2) + "\n")
    print(f"Built {SPEC.version}: {OUTPUT.relative_to(ROOT)}/libbox.aar")


if __name__ == "__main__":
    main()
