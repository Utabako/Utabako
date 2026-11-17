#!/usr/bin/env python3
"""Collect exact libbox sources and notices, using only the Python standard library.

Run from the repository root with --cache PATH; the core checkout and buildinfo
default to the current libbox build. Subsequent runs can use --offline.
Module zip h1 verification follows golang.org/x/mod/sumdb/dirhash.HashZip (Hash1), not zip SHA.
The source archives and manifest belong in the corresponding-source release.
"""

import argparse
import base64
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import tarfile
from typing import TypedDict
from urllib.request import urlopen
import zipfile

from build_libbox import OUTPUT, SOURCE, SPEC

CORE_PATH = "github.com/sagernet/sing-box"
CORE_COMMIT = SPEC.commit
CORE_H1 = SPEC.source_h1
GO_VERSION = SPEC.go_version
GO_SOURCE_SHA256 = "e988d4a2446ac7fe3f6daa089a58e9936a52a381355adec1c8983230a8d6c59e"
LEGAL_NAME = re.compile(r"^(licen[cs]e|copying|notice|authors|contributors|copyright|patents|unlicense)(?:$|[._-])", re.I)
LEGAL_WORD = re.compile(r"copyright|licen[cs]e|public domain|permission is hereby|all rights reserved|incompatible with secondary", re.I)
COMMENTS = re.compile(r"/\*.*?\*/|(?m:^[ \t]*//[^\n]*(?:\n[ \t]*//[^\n]*)*)", re.S)
SOURCE_SUFFIXES = {".go", ".c", ".cc", ".cpp", ".h", ".hpp", ".s", ".S", ".rs", ".java"}


@dataclass(frozen=True)
class Module:
    path: str
    version: str
    h1: str
    original_path: str
    original_version: str


@dataclass
class Material:
    module: Module
    archive: str
    zip_sha256: str
    notices: list[tuple[list[str], str]]


class ModuleRecord(TypedDict):
    path: str
    version: str
    h1: str
    original_path: str
    original_version: str
    archive: str
    zip_sha256: str
    notice_paths: list[str]


class GoRecord(TypedDict):
    version: str
    archive: str
    sha256: str
    source_url: str
    notice_paths: list[str]


class Manifest(TypedDict):
    buildinfo_sha256: str
    core_commit: str
    modules: list[ModuleRecord]
    toolchain: GoRecord


def parse_buildinfo(text: str) -> list[Module]:
    if text.splitlines()[0].split()[-1] != GO_VERSION:
        raise ValueError("Buildinfo Go version differs from the pinned toolchain")
    if [line.split() for line in text.splitlines() if line.split()[:1] == ["mod"]] != [["mod", CORE_PATH, "(devel)"]]:
        raise ValueError("Buildinfo main module differs from the pinned source")
    modules: list[Module] = []
    for line in text.splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "dep":
            if len(fields) not in (3, 4):
                raise ValueError(f"Invalid dependency: {line}")
            modules.append(Module(fields[1], fields[2], fields[3] if len(fields) == 4 else "", fields[1], fields[2]))
        elif fields[0] == "=>":
            if not modules or len(fields) != 4:
                raise ValueError(f"Unpinned replacement: {line}")
            original = modules[-1]
            modules[-1] = Module(fields[1], fields[2], fields[3], original.original_path, original.original_version)
    if not modules or any(not module.h1.startswith("h1:") for module in modules):
        raise ValueError("Every compiled dependency must have an exact version and h1 checksum")
    if len({(module.path, module.version) for module in modules}) != len(modules):
        raise ValueError("Duplicate compiled module")
    return modules


def escape(value: str) -> str:
    return "".join("!" + char.lower() if char.isupper() else char for char in value)


def zip_h1(archive: Path, prefix: str) -> str:
    summary = hashlib.sha256()
    with zipfile.ZipFile(archive) as source:
        names = source.namelist()
        if len(names) != len(set(names)):
            raise ValueError(f"Duplicate zip entry: {archive}")
        for name in sorted(names):
            if not name.startswith(prefix) or "\n" in name or ".." in PurePosixPath(name).parts:
                raise ValueError(f"Invalid module zip entry: {name}")
            with source.open(name) as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            summary.update(f"{digest}  {name}\n".encode())
    return "h1:" + base64.b64encode(summary.digest()).decode()


def atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(content)
            stream.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def fetch_module(module: Module, cache: Path, proxy: str, offline: bool) -> Path:
    relative = Path(escape(module.path)) / "@v" / (escape(module.version) + ".zip")
    archive = cache / relative
    prefix = f"{module.path}@{module.version}/"
    if archive.exists():
        actual = zip_h1(archive, prefix)
        if actual != module.h1:
            raise ValueError(f"Cached h1 mismatch for {module.path}: {actual} != {module.h1}")
        return archive
    if offline:
        raise FileNotFoundError(f"Missing cached module: {archive}")
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=archive.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            with urlopen(f"{proxy.rstrip('/')}/{relative.as_posix()}", timeout=120) as response:
                shutil.copyfileobj(response, stream)
            stream.close()
            actual = zip_h1(temporary, prefix)
            if actual != module.h1:
                raise ValueError(f"Downloaded h1 mismatch for {module.path}: {actual} != {module.h1}")
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    return archive


def source_entries(archive: Path) -> Iterator[tuple[str, bytes]]:
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as source:
            for name in sorted(source.namelist()):
                if not name.endswith("/"):
                    yield name, source.read(name)
    else:
        with tarfile.open(archive, "r:gz") as source:
            for member in sorted(source.getmembers(), key=lambda item: item.name):
                if member.isfile():
                    stream = source.extractfile(member)
                    assert stream is not None
                    with stream:
                        yield member.name, stream.read()


def collect_notices(archive: Path, prefix: str) -> list[tuple[list[str], str]]:
    # Conservatively retain notices throughout each compiled module, not just
    # selected package files. Identical comments keep every original path.
    notices: dict[str, list[str]] = {}
    license_files = 0
    for name, content in source_entries(archive):
        if not name.startswith(prefix):
            raise ValueError(f"Unexpected source archive path: {name}")
        relative = name.removeprefix(prefix)
        path = PurePosixPath(relative)
        legal_file = bool(LEGAL_NAME.match(path.name)) or any(part.lower() in {"licenses", "licences"} for part in path.parts[:-1])
        if legal_file:
            text = content.decode("utf-8-sig")
            if not text.strip():
                raise ValueError(f"Empty notice: {archive}:{relative}")
            notices.setdefault(text, []).append(relative)
            license_files += 1
        elif path.suffix in SOURCE_SUFFIXES:
            text = content.decode("utf-8-sig", errors="surrogateescape")
            for comment in COMMENTS.findall(text):
                if LEGAL_WORD.search(comment):
                    notices.setdefault(comment, []).append(relative + " (source comment)")
    if not license_files:
        raise ValueError(f"No license/notice file in {archive}; investigate the original repository/parent license")
    return [(paths, text) for text, paths in notices.items()]


def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def collect_module(module: Module, cache: Path, proxy: str, offline: bool) -> Material:
    archive = fetch_module(module, cache, proxy, offline)
    notices = collect_notices(archive, f"{module.path}@{module.version}/")
    return Material(module, archive.relative_to(cache).as_posix(), sha256_file(archive), notices)


def collect_core(cache: Path, checkout: Path | None, offline: bool) -> Material:
    archive = cache / "sing-box" / (CORE_COMMIT + ".zip")
    prefix = f"{CORE_PATH}@{CORE_COMMIT}/"
    if not archive.exists():
        if offline or checkout is None:
            raise FileNotFoundError("Core archive missing; pass --core-source with the exact commit available")
        content = subprocess.check_output(["git", "-C", str(checkout), "archive", "--format=zip", f"--prefix={prefix}", CORE_COMMIT])
        atomic_write(archive, content)
    with zipfile.ZipFile(archive) as source:
        if source.comment.decode() != CORE_COMMIT:
            raise ValueError("Core archive does not identify the pinned source commit")
    h1 = zip_h1(archive, prefix)
    if h1 != CORE_H1:
        raise ValueError(f"Pinned sing-box source h1 mismatch: {h1}")
    module = Module(CORE_PATH, CORE_COMMIT, h1, CORE_PATH, "(devel)")
    return Material(module, archive.relative_to(cache).as_posix(), sha256_file(archive), collect_notices(archive, prefix))


def collect_go(cache: Path, offline: bool) -> tuple[GoRecord, list[tuple[list[str], str]]]:
    archive = cache / (GO_VERSION + ".src.tar.gz")
    url = "https://go.dev/dl/" + archive.name
    if not archive.exists():
        if offline:
            raise FileNotFoundError(f"Missing Go source archive: {archive}")
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stream:
            temporary = Path(stream.name)
            try:
                with urlopen(url, timeout=120) as response:
                    shutil.copyfileobj(response, stream)
                stream.close()
                if sha256_file(temporary) != GO_SOURCE_SHA256:
                    raise ValueError("Go source archive checksum mismatch")
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
    if sha256_file(archive) != GO_SOURCE_SHA256:
        raise ValueError("Cached Go source archive checksum mismatch")
    notices = collect_notices(archive, "go/")
    record: GoRecord = {
        "version": GO_VERSION, "archive": archive.name, "sha256": GO_SOURCE_SHA256,
        "source_url": url, "notice_paths": [path for paths, _ in notices for path in paths],
    }
    return record, notices


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--buildinfo", type=Path, default=OUTPUT / "libbox.buildinfo.txt")
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("licenses/native.txt"))
    parser.add_argument("--core-source", type=Path, default=SOURCE)
    parser.add_argument("--proxy", default="https://proxy.golang.org")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()
    buildinfo = args.buildinfo.read_text()
    modules = parse_buildinfo(buildinfo)
    args.cache.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        materials = list(pool.map(lambda module: collect_module(module, args.cache, args.proxy, args.offline), modules))
    materials.insert(0, collect_core(args.cache, args.core_source, args.offline))
    toolchain, go_notices = collect_go(args.cache, args.offline)
    manifest: Manifest = {
        "buildinfo_sha256": hashlib.sha256(buildinfo.encode()).hexdigest(),
        "core_commit": CORE_COMMIT, "modules": [], "toolchain": toolchain,
    }
    output = ["Utabako libbox native third-party notices\n", "Flutter/Android dependencies are listed separately.\n", "Notices are conservatively retained throughout each compiled module, including unused package files.\n", "Original license files and source comments follow; paths are relative to each component.\n"]
    for material in materials:
        module = material.module
        output.extend(["\n" + "=" * 80 + "\n", f"Component: {module.path}\nVersion: {module.version}\nh1: {module.h1}\n"])
        if module.original_path != module.path:
            output.append(f"Replaces: {module.original_path}@{module.original_version}\n")
        paths: list[str] = []
        for original_paths, text in material.notices:
            paths.extend(original_paths)
            output.append("\n--- " + "\n    ".join(original_paths) + " ---\n")
            output.append(text)
            output.append("\n")
        manifest["modules"].append({
            "path": module.path, "version": module.version, "h1": module.h1,
            "original_path": module.original_path, "original_version": module.original_version,
            "archive": material.archive, "zip_sha256": material.zip_sha256, "notice_paths": paths,
        })
    output.extend(["\n" + "=" * 80 + "\n", f"Component: Go runtime / standard library\nVersion: {GO_VERSION}\n"])
    for original_paths, text in go_notices:
        output.extend(["\n--- " + "\n    ".join(original_paths) + " ---\n", text, "\n"])
    atomic_write(args.output, "".join(output).encode())
    atomic_write(args.cache / "manifest.json", (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode())
    print(f"Collected {len(modules)} compiled dependency modules + pinned sing-box core + {GO_VERSION}; {sum(len(item.notices) for item in materials) + len(go_notices)} original notice texts")
    print(f"Sources and manifest: {args.cache}\nNotices: {args.output}")


if __name__ == "__main__":
    main()
