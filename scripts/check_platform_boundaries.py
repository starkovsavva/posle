#!/usr/bin/env python3
"""Check Swift source and target boundaries without resolving package dependencies."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PORTABLE_IMPORTS = {
    "AfterCore": {"Foundation"},
    "AfterPlatform": {"Foundation", "AfterCore"},
    "AfterLocalization": {"Foundation", "Observation"},
}
MODULES = (*PORTABLE_IMPORTS, "AfterPlatformMacOS")
TARGET_DEPENDENCIES = {
    "AfterCore": set(),
    "AfterPlatform": {"AfterCore"},
    "AfterLocalization": set(),
    "AfterPlatformMacOS": {"AfterCore", "AfterPlatform", "AfterLocalization"},
}
COORDINATORS = (
    "AppStore", "RecordingCoordinator", "BackgroundJobs", "QuickCapture",
    "CalendarStore", "VoiceCommands", "ChatGPTAccount",
)
NATIVE_SERVICES = {
    "AVFoundation", "ScreenCaptureKit", "EventKit", "IOKit", "Carbon",
    "Security", "Darwin", "Network", "CoreAudio", "AudioToolbox", "CoreMedia", "CoreVideo",
}
IMPORT = re.compile(r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_]\w*)")


def swift_code(source: str) -> str:
    """Mask comments and Swift strings, preserving offsets and line numbers.

    Deliberately do not evaluate #if: inactive branches obey the same boundary.
    Nested comments and raw/multiline string delimiters are supported. This is a
    lexical architecture guard, not a replacement for the Swift compiler.
    """
    output = list(source)
    index = 0

    def mask(start: int, end: int) -> None:
        for position in range(start, end):
            if output[position] != "\n":
                output[position] = " "

    while index < len(source):
        start = index
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
        elif source.startswith("/*", index):
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        else:
            quote = index
            while quote < len(source) and source[quote] == "#":
                quote += 1
            if quote >= len(source) or source[quote] != '"':
                index += 1
                continue
            hashes = source[index:quote]
            delimiter = '"""' if source.startswith('"""', quote) else '"'
            closing = delimiter + hashes
            index = quote + len(delimiter)
            while index < len(source):
                if source.startswith("\\" + hashes, index):
                    index += len(hashes) + 2
                elif source.startswith(closing, index):
                    index += len(closing)
                    break
                else:
                    index += 1
            index = min(index, len(source))
        mask(start, index)
    return "".join(output)


def source_violations(relative: Path, source: str) -> list[str]:
    parts = relative.parts
    if len(parts) < 3 or parts[0] != "Sources":
        return []
    module = parts[1]
    code = swift_code(source)
    diagnostics: list[str] = []
    coordinator = module == "AfterApp" and len(parts) == 3 and relative.stem in COORDINATORS
    for match in IMPORT.finditer(code):
        imported = match.group(1)
        reason = None
        if module in PORTABLE_IMPORTS and imported not in PORTABLE_IMPORTS[module]:
            reason = f"{module} may import only {', '.join(sorted(PORTABLE_IMPORTS[module]))}; found {imported}"
        elif module in MODULES and imported in {"AfterApp", "AppStore"}:
            reason = f"{module} cannot depend on application module {imported}"
        elif coordinator and imported in NATIVE_SERVICES:
            reason = f"workflow coordinator must use a platform port instead of importing {imported}"
        if reason:
            line = code.count("\n", 0, match.start()) + 1
            diagnostics.append(f"{relative.as_posix()}:{line}: {reason}")
    if module in MODULES:
        for match in re.finditer(r"\bAppStore\b", code):
            # Import diagnostics already explain this spelling at an import site.
            line_start = code.rfind("\n", 0, match.start()) + 1
            if IMPORT.search(code[line_start:match.end()]):
                continue
            line = code.count("\n", 0, match.start()) + 1
            diagnostics.append(f"{relative.as_posix()}:{line}: platform modules cannot reference AppStore")
    return diagnostics


def check_ignored_swift_sources(root: Path) -> list[str]:
    """Inspect every compiled source area, including the native app target.

    --no-index deliberately checks tracked paths too: an ignore rule may hide
    the next source added beside an already tracked file. NUL framing keeps
    spaces and non-ASCII paths intact and never expands shell arguments.
    """
    paths = sorted(path.relative_to(root).as_posix()
                   for path in (root / "Sources").rglob("*.swift") if path.is_file())
    if not paths:
        return []
    result = subprocess.run(
        ["git", "-C", str(root), "check-ignore", "--no-index", "-z", "--stdin"],
        input=b"".join(os.fsencode(path) + b"\0" for path in paths),
        capture_output=True, check=False, timeout=30,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError("Could not inspect Swift source ignore rules: git check-ignore failed")
    ignored = [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]
    return [f"{path}: Swift source is ignored by Git and may be absent from a clean checkout"
            for path in ignored]


def check_sources(root: Path) -> list[str]:
    diagnostics = check_ignored_swift_sources(root)
    for module in MODULES:
        directory = root / "Sources" / module
        if not directory.is_dir():
            diagnostics.append(f"Sources/{module}: required module source directory is missing")
            continue
        for path in sorted(directory.rglob("*.swift")):
            diagnostics.extend(source_violations(path.relative_to(root), path.read_text()))
    for name in COORDINATORS:
        path = root / "Sources" / "AfterApp" / f"{name}.swift"
        if not path.is_file():
            diagnostics.append(f"Sources/AfterApp/{name}.swift: expected workflow coordinator is missing")
        else:
            diagnostics.extend(source_violations(path.relative_to(root), path.read_text()))
    # App Diagnostics intentionally import SDKs and @testable adapters for native
    # fakes. They are compiled separately from portable module unit tests.
    return diagnostics


def check_graph(package: dict) -> list[str]:
    targets = package.get("targets", [])
    graph: dict[str, set[str]] = {}
    diagnostics = []
    local_products = {product["name"]: product.get("targets", []) for product in package.get("products", [])}
    for target in targets:
        name = target["name"]
        if name in graph:
            diagnostics.append(f"Package.swift: duplicate target {name}")
        dependencies = set()
        for dependency in target.get("dependencies", []):
            kind = next((key for key in ("byName", "target", "product") if key in dependency), None)
            if kind is None or not isinstance(dependency[kind], list) or not dependency[kind]:
                diagnostics.append(f"Package.swift: unsupported dependency declaration in {name}: {dependency}")
                continue
            value = dependency[kind][0]
            # A product with an explicit package is external, even if its name
            # shadows a local target. Never let that bypass a contract boundary.
            external = kind == "product" and len(dependency[kind]) > 1 and dependency[kind][1] is not None
            if external:
                dependencies.add(f"external:{value}")
            elif kind == "product" and value in local_products:
                dependencies.update(local_products[value])
            else:
                dependencies.add(value)
        graph[name] = dependencies
    for required in PORTABLE_IMPORTS:
        if required not in graph:
            diagnostics.append(f"Package.swift: required portable target {required} is missing")
    for name, allowed in TARGET_DEPENDENCIES.items():
        for dependency in sorted(graph.get(name, set()) - allowed):
            diagnostics.append(f"Package.swift: {name} cannot depend on {dependency}")
    active: list[str] = []
    visited: set[str] = set()

    def visit(name: str) -> None:
        if name in active:
            diagnostics.append("Package.swift: dependency cycle: " + " -> ".join(active[active.index(name):] + [name]))
            return
        if name in visited:
            return
        active.append(name)
        for dependency in sorted(graph[name]):
            if dependency in graph:
                visit(dependency)
        active.pop()
        visited.add(name)

    for name in sorted(graph):
        visit(name)
    return diagnostics


def dump_package(root: Path, disable_sandbox: bool = False) -> dict:
    # dump-package evaluates the local manifest only. It does not resolve, fetch
    # or build dependencies; source scanning also covers inactive host branches.
    cache = root / ".build" / "platform-boundary-cache"
    cache.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.setdefault("CLANG_MODULE_CACHE_PATH", str(cache / "clang"))
    environment.setdefault("SWIFTPM_MODULECACHE_OVERRIDE", str(cache / "swift"))
    command = ["swift", "package", "--package-path", str(root), "--manifest-cache", "local"]
    if disable_sandbox:
        command.append("--disable-sandbox")
    command.append("dump-package")
    result = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=120)
    if result.returncode:
        raise RuntimeError("swift package dump-package failed:\n" + result.stderr.strip())
    return json.loads(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--package-json", type=Path, help="Use an already generated swift package dump-package JSON")
    parser.add_argument("--disable-sandbox", action="store_true", help="Pass SwiftPM's flag when running inside an existing restricted sandbox")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        package = json.loads(args.package_json.read_text()) if args.package_json else dump_package(root, args.disable_sandbox)
        diagnostics = check_sources(root) + check_graph(package)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 1
    if diagnostics:
        print("\n".join(diagnostics), file=sys.stderr)
        return 1
    print("Platform boundaries passed: non-ignored Swift sources, portable imports, workflow ports and acyclic package graph")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
