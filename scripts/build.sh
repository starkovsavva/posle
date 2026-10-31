#!/bin/bash
set -euo pipefail
umask 022
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${POSLE_BUILD_DIR:-$PROJECT/.build}"
cd "$PROJECT"
# Refuse ignored Swift implementation files: a local build must not succeed
# with inputs that a clean checkout and the published source archive omit.
python3 "$PROJECT/scripts/check_platform_boundaries.py"
# Validate a requested Apple identity before building. An unset identity keeps
# the existing ad-hoc development signature.
python3 "$PROJECT/scripts/signing.py" --check
SOURCE_REVISION="$(git rev-parse --verify HEAD)"
SOURCE_STATUS="$(git status --porcelain)"
mkdir -p "$PROJECT/dist"
STAGING="$(mktemp -d "$PROJECT/dist/.posle-build.XXXXXX")"
APP="$STAGING/After.app"
trap 'rm -rf "$STAGING"' EXIT

# Rust is required only on the developer's machine; users run the bundled binary.
if [[ -n "${POSLE_CARGO_HOME:-}" ]]; then
    export CARGO_HOME="$POSLE_CARGO_HOME"
    CARGO="$CARGO_HOME/bin/cargo"
    if [[ ! -x "$CARGO" ]]; then
        echo "Не найден Cargo: $CARGO. Выполните scripts/setup-rust.sh с тем же POSLE_CARGO_HOME." >&2
        exit 1
    fi
    export RUSTUP_HOME="${POSLE_RUSTUP_HOME:-${RUSTUP_HOME:-$PROJECT/.toolchain/rustup}}"
elif command -v cargo >/dev/null 2>&1; then
    CARGO="$(command -v cargo)"
    if [[ -n "${POSLE_RUSTUP_HOME:-}" ]]; then
        export RUSTUP_HOME="$POSLE_RUSTUP_HOME"
    fi
elif [[ -x "$PROJECT/.toolchain/cargo/bin/cargo" ]]; then
    export CARGO_HOME="$PROJECT/.toolchain/cargo"
    export RUSTUP_HOME="${POSLE_RUSTUP_HOME:-$PROJECT/.toolchain/rustup}"
    CARGO="$CARGO_HOME/bin/cargo"
else
    echo "Не найден Cargo. Выполните scripts/setup-rust.sh или укажите POSLE_CARGO_HOME с установленным Cargo." >&2
    exit 1
fi
export PATH="$(dirname "$CARGO"):$PATH"
RUST_BUILD="${POSLE_RUST_TARGET_DIR:-$BUILD/rust}"
if [[ "$(uname -m)" == "arm64" ]]; then
    "$CARGO" build --manifest-path "$PROJECT/rust-core/Cargo.toml" \
        --release --locked --target-dir "$RUST_BUILD"
    RUST_RELEASE="$RUST_BUILD/release"
else
    "$CARGO" build --manifest-path "$PROJECT/rust-core/Cargo.toml" \
        --release --locked --target aarch64-apple-darwin --target-dir "$RUST_BUILD"
    RUST_RELEASE="$RUST_BUILD/aarch64-apple-darwin/release"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/backend"
CORE_LIBRARY="$APP/Contents/Frameworks/libposle_core.dylib"
CORE_DIGEST="$STAGING/core.sha256"
cp "$RUST_RELEASE/libposle_core.dylib" "$CORE_LIBRARY"
chmod 755 "$CORE_LIBRARY"
install_name_tool -id @rpath/libposle_core.dylib "$CORE_LIBRARY"
# The final signed bytes must exist before linking the executable's trusted
# digest. Final app signing preserves this library instead of timestamping it again.
python3 "$PROJECT/scripts/signing.py" --library "$CORE_LIBRARY" --digest-file "$CORE_DIGEST"
swift build --scratch-path "$BUILD" -c release --disable-automatic-resolution \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __posle_core -Xlinker "$CORE_DIGEST"
SWIFT_BIN="$(swift build --scratch-path "$BUILD" -c release --show-bin-path)"
cp "$SWIFT_BIN/After" "$APP/Contents/MacOS/After"
cp "$RUST_RELEASE/posle-engine" "$APP/Contents/MacOS/After Engine"
# Previously copied MCP configurations refer to posle-engine. A signed native
# shim keeps that path usable and execs the newly named engine without a shell.
/usr/bin/clang -Os -std=c11 -Wall -Wextra -Werror "$PROJECT/packaging/LegacyEngineShim.c" -o "$APP/Contents/MacOS/posle-engine"
# Keep helper bundle paths and identifiers stable for existing installations.
# Their executable names are user-visible in Activity Monitor.
python3 - "$APP" "$RUST_RELEASE/posle-engine" "$PROJECT/packaging/Info.plist" <<'PYHELPERS'
import plistlib, shutil, sys
from pathlib import Path
app, engine, version_file = map(Path, sys.argv[1:])
with version_file.open("rb") as stream: version = plistlib.load(stream)
# Keep helper bundle paths and identifiers stable for runtime integrity checks.
for title, executable, identifier, display in [
    ("После Распознавание", "After Speech", "app.posle.meetings.speech", "After Speech"),
    ("После Обработка", "After Processing", "app.posle.meetings.processing", "After Processing"),
]:
    helper = app / "Contents/Helpers" / (title + ".app") / "Contents"
    (helper / "MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copy2(engine, helper / "MacOS" / executable)
    with (helper / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleName": display, "CFBundleDisplayName": display,
                      "CFBundleExecutable": executable, "CFBundleIdentifier": identifier,
                      "CFBundlePackageType": "APPL", "CFBundleVersion": version["CFBundleVersion"],
                      "CFBundleShortVersionString": version["CFBundleShortVersionString"], "LSBackgroundOnly": True,
                      "LSMinimumSystemVersion": "15.0"}, stream, sort_keys=False)
PYHELPERS
# The checkout identity is embedded in the signed app, so release tooling can
# reject a stale bundle built from another commit.
python3 - "$PROJECT/packaging/Info.plist" "$APP/Contents/Info.plist" "$SOURCE_REVISION" "$SOURCE_STATUS" <<'PYINFO'
import plistlib, re, sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:3])
revision = sys.argv[3]
if not re.fullmatch(r"[0-9a-f]{40}", revision):
    raise SystemExit("Invalid source revision")
with source.open("rb") as stream:
    info = plistlib.load(stream)
info["PosleSourceRevision"] = revision
info["PosleSourceClean"] = not sys.argv[4]
with destination.open("wb") as stream:
    plistlib.dump(info, stream, sort_keys=False)
PYINFO
# SwiftPM's build products contain the selected framework slice. ditto keeps
# its versioned symlinks and upstream signatures, including Sparkle's helpers.
SPARKLE="$SWIFT_BIN/Sparkle.framework"
if [[ ! -d "$SPARKLE" ]]; then
    echo "Не найден framework Sparkle в продуктах SwiftPM: $SPARKLE" >&2
    exit 1
fi
codesign --verify --deep --strict "$SPARKLE"
ditto --noextattr --norsrc --noqtn "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --verify --deep --strict "$APP/Contents/Frameworks/Sparkle.framework"
cp "$PROJECT/backend/engine.py" "$PROJECT/backend/models.py" "$PROJECT/backend/media_runtime.py" "$PROJECT/backend/cloud_speech.py" "$PROJECT/backend/embedded_bridge.py" "$PROJECT/backend/short_speech.py" "$PROJECT/backend/setup.sh" "$PROJECT/backend/requirements.txt" "$PROJECT/backend/python-runtime.json" "$APP/Contents/Resources/backend/"
# SwiftPM owns the shared translation catalog. Keep its resource bundle beside
# the executable's resources so Bundle.module also resolves after distribution.
LOCALIZATION_BUNDLE="$SWIFT_BIN/After_AfterLocalization.bundle"
if [[ ! -d "$LOCALIZATION_BUNDLE" ]]; then
    echo "Missing AfterLocalization resource bundle: $LOCALIZATION_BUNDLE" >&2
    exit 1
fi
ditto --noextattr --norsrc --noqtn "$LOCALIZATION_BUNDLE" "$APP/Contents/Resources/After_AfterLocalization.bundle"
mkdir -p "$APP/Contents/Resources/Localization"
cp "$PROJECT/Sources/AfterLocalization/Resources/en.json" "$APP/Contents/Resources/Localization/en.json"
cp -R "$PROJECT/packaging/en.lproj" "$PROJECT/packaging/ru.lproj" "$APP/Contents/Resources/"
cp "$PROJECT/THIRD_PARTY.md" "$APP/Contents/Resources/THIRD_PARTY.md"
cp "$PROJECT/LICENSE" "$APP/Contents/Resources/LICENSE"
swift "$PROJECT/scripts/icon.swift" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
python3 "$PROJECT/scripts/signing.py" --app "$APP" \
    --entitlements "$PROJECT/packaging/entitlements.plist" --presigned-core-sha256 "$CORE_DIGEST"
codesign --verify --deep --strict "$APP"
if [[ "$(git rev-parse --verify HEAD)" != "$SOURCE_REVISION" || "$(git status --porcelain)" != "$SOURCE_STATUS" ]]; then
    echo "Исходный коммит изменился во время сборки; повторите сборку." >&2
    exit 1
fi
# Publish only a complete verified bundle. On macOS RENAME_SWAP atomically
# exchanges two existing directories on the same volume; the old bundle stays
# in our disposable staging folder until cleanup.
python3 - "$APP" "$PROJECT/dist/After.app" <<'PYPUBLISH'
import ctypes, os, sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
if source.is_symlink() or not source.is_dir() or destination.is_symlink():
    raise SystemExit("Expected regular application bundle paths")
if not destination.exists():
    os.rename(source, destination)
else:
    if not destination.is_dir():
        raise SystemExit("Application destination is not a directory")
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    renamex = library.renameatx_np
    renamex.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renamex.restype = ctypes.c_int
    if renamex(-2, os.fsencode(source), -2, os.fsencode(destination), 0x00000002) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))
PYPUBLISH
APP="$PROJECT/dist/After.app"
bash "$PROJECT/scripts/package.sh"
echo "Готово: $APP"
