#!/usr/bin/env bash
# Build a Linux AppImage for the LoveACE Flutter desktop app.
#
# Works both locally and on CI (ubuntu-latest). Requires:
#   - flutter (stable, Linux desktop enabled) on PATH
#   - cmake, ninja, clang, pkg-config, gtk+-3.0 dev headers
#   - python3 (+ Pillow) only when regenerating the icon; a prebuilt icon
#     ships in this directory so CI does not need Pillow
#   - network on first run to download the pinned appimagetool and type-2
#     runtime (cached beside this script and sha256-verified on every run)
#
# Optional env (analytics, mirrors the macOS/Windows workflows):
#   ANALYTICS_ENDPOINT, ANALYTICS_API_KEY, ANALYTICS_SIGNING_SECRET, ANALYTICS_HASH_SALT
#
# Usage: ./build-appimage.sh
# Output: ../../build/appimage/LoveACE-<version>-x86_64.AppImage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$DESKTOP_DIR")"
OUT_DIR="$DESKTOP_DIR/build/appimage"
ID="io.github.yeningyuan08.LoveACE"

APPIMAGE_TOOL="${APPIMAGE_TOOL:-$SCRIPT_DIR/appimagetool-x86_64.AppImage}"
APPIMAGE_TOOL_VERSION="1.9.1"
# sha256 of appimagetool-x86_64.AppImage published with the 1.9.1 release.
APPIMAGE_TOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
APPIMAGE_TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/${APPIMAGE_TOOL_VERSION}/appimagetool-x86_64.AppImage"

# The type-2 runtime that gets prepended to the AppImage. appimagetool does not
# embed it, so without --runtime-file it silently downloads the *moving*
# `continuous` runtime on every pack, which makes the output depend on the day
# it was built. Pin the dated release tag instead.
RUNTIME_FILE="${APPIMAGE_RUNTIME_FILE:-$SCRIPT_DIR/runtime-x86_64}"
RUNTIME_VERSION="20251108"
RUNTIME_SHA256="2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"
RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/${RUNTIME_VERSION}/runtime-x86_64"

ICON_SOURCE="$SCRIPT_DIR/$ID.png"

# --- Version from pubspec -------------------------------------------------
version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+).*/\1/p' "$DESKTOP_DIR/pubspec.yaml" | head -1)"
build="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+).*/\2/p' "$DESKTOP_DIR/pubspec.yaml" | head -1)"
if [ -z "$version" ] || [ -z "$build" ]; then
  echo "error: cannot read version from desktop/pubspec.yaml" >&2
  exit 1
fi
echo "==> LoveACE desktop version: $version+$build"

# Record the toolchain actually used so a local run can be compared with CI.
flutter_version="$(flutter --version 2>/dev/null | sed -n '1p' || true)"
echo "==> Flutter toolchain: ${flutter_version:-unknown}"

# --- Pinned, sha256-verified build inputs ----------------------------------
# Both the packer and the runtime are pinned to tagged releases instead of the
# moving `continuous` tags: a reproducible AppImage requires that the same
# inputs are packed by the same tool. Cached copies beside this script are
# reused offline, but only when their digest matches the pinned value.
# Override APPIMAGE_TOOL / APPIMAGE_RUNTIME_FILE to point at copies that were
# pre-downloaded for an offline build.
#
# Resolved before the Flutter build on purpose: a missing or tampered input
# should fail the run immediately instead of after several minutes of compiling.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# fetch_verified <path> <url> <sha256> <label>
fetch_verified() {
  local path="$1" url="$2" expected="$3" label="$4"
  local actual_sha256
  if [ -f "$path" ] && [ "$(sha256_of "$path")" = "$expected" ]; then
    echo "==> Using cached $label (sha256 verified)"
    return 0
  fi
  if [ -e "$path" ]; then
    echo "==> Cached $label has an unexpected digest, re-downloading" >&2
    rm -f "$path"
  fi
  echo "==> Downloading $label"
  if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 300 -o "$path.tmp" "$url"; then
    rm -f "$path.tmp"
    echo "error: cannot download $label" >&2
    echo "error: url: $url" >&2
    echo "error: for an offline build, place the file at:" >&2
    echo "error:   $path" >&2
    echo "error: expected sha256: $expected" >&2
    return 1
  fi
  actual_sha256="$(sha256_of "$path.tmp")"
  if [ "$actual_sha256" != "$expected" ]; then
    rm -f "$path.tmp"
    echo "error: $label sha256 mismatch" >&2
    echo "error:   expected: $expected" >&2
    echo "error:   actual:   $actual_sha256" >&2
    return 1
  fi
  mv "$path.tmp" "$path"
  return 0
}

if ! fetch_verified "$APPIMAGE_TOOL" "$APPIMAGE_TOOL_URL" "$APPIMAGE_TOOL_SHA256" \
     "appimagetool $APPIMAGE_TOOL_VERSION"; then
  echo "error: refusing to pack with an unverified appimagetool" >&2
  exit 1
fi
chmod +x "$APPIMAGE_TOOL"

if ! fetch_verified "$RUNTIME_FILE" "$RUNTIME_URL" "$RUNTIME_SHA256" \
     "type2 runtime $RUNTIME_VERSION"; then
  echo "error: refusing to pack with an unverified runtime" >&2
  exit 1
fi
chmod +x "$RUNTIME_FILE"

# --- Optional analytics dart-defines --------------------------------------
dart_defines=()
for key in ANALYTICS_ENDPOINT ANALYTICS_API_KEY ANALYTICS_SIGNING_SECRET ANALYTICS_HASH_SALT; do
  if [ -n "${!key:-}" ]; then
    dart_defines+=( "--dart-define=$key=${!key}" )
  fi
done

# --- Get dependencies & build the Linux bundle ----------------------------
( cd "$DESKTOP_DIR" && flutter pub get )
( cd "$DESKTOP_DIR" && flutter build linux --release "${dart_defines[@]}" )

BUNDLE="$DESKTOP_DIR/build/linux/x64/release/bundle"

# --- Icon (regenerate from the repo logo only when the shipped one is gone) -
if [ ! -f "$ICON_SOURCE" ]; then
  echo "==> Regenerating icon from assets/logo.png"
  python3 - "$ROOT_DIR/assets/logo.png" "$ICON_SOURCE" <<'PY'
import sys
try:
    from PIL import Image
except ImportError:
    print("error: Pillow not available to regenerate icon; commit desktop/appimage/%s.png" % sys.argv[2].rsplit('/', 1)[-1], file=sys.stderr)
    raise SystemExit(1)
im = Image.open(sys.argv[1]).convert('RGBA').resize((512, 512), Image.LANCZOS)
im.save(sys.argv[2], 'PNG')
PY
fi

# --- Assemble AppDir --------------------------------------------------------
echo "==> Assembling AppDir"
APPDIR="$OUT_DIR/loveace.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/lib/loveace" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/512x512/apps" \
         "$APPDIR/usr/share/metainfo"

# Keep the Flutter bundle layout intact so $ORIGIN/lib and data/ resolve
cp -a "$BUNDLE/." "$APPDIR/usr/lib/loveace/"

# --- Drop Android-only artifacts -------------------------------------------
# libdartjni.so is emitted by the `jni` package's host build but nothing in the
# Linux bundle links against it (it is the only object whose NEEDED list pulls
# in libjvm.so). Leaving it in makes the AppDir contents depend on whether a JDK
# happens to be installed on the build machine, which breaks reproducibility.
for android_only in libdartjni.so; do
  if [ -e "$APPDIR/usr/lib/loveace/lib/$android_only" ]; then
    echo "==> Excluding Android-only $android_only"
    rm -f "$APPDIR/usr/lib/loveace/lib/$android_only"
  fi
done

# Bundle libsecret with its private dependency closure.
# flutter_secure_storage_linux is linked into the main binary, so its
# DT_NEEDED entry libsecret-1.so.0 must be resolvable at process start:
# on systems without libsecret installed the whole AppImage would fail to
# launch with a dynamic-linker error. Walk the transitive closure but skip
# the glib/GTK stack and other base system libraries that any GTK3-capable
# host is guaranteed to provide (bundling those would risk ABI mismatches
# with the host GTK3 the app loads at runtime).
echo "==> Bundling libsecret runtime closure"
{
  target_dir="$APPDIR/usr/lib/loveace/lib"
  skip_re='^(ld-linux|libc\.so|libm\.so|libpthread\.so|libdl\.so|librt\.so|libresolv\.so|libutil\.so|libgcc_s\.so|libstdc\+\+\.so|libz\.so|liblzma\.so|libglib-2\.0\.so|libgio-2\.0\.so|libgobject-2\.0\.so|libgmodule-2\.0\.so|libffi\.so|libpcre2-8\.so|libselinux\.so|libmount\.so|libblkid\.so|libsystemd\.so|libudev\.so|libcap\.so|libcrypto\.so|libssl\.so)'
  queue=(libsecret-1.so.0)
  declare -A seen=()
  while [ "${#queue[@]}" -gt 0 ]; do
    lib="${queue[0]}"; queue=("${queue[@]:1}")
    case "$lib" in
      linux-vdso*|linux-gate*|/*) continue ;;
    esac
    [ -n "${seen[$lib]:-}" ] && continue
    seen["$lib"]=1
    if printf '%s' "$lib" | grep -Eq "$skip_re"; then continue; fi
    # Note: no early-exit parsing here (awk exit / grep -m1 / head would
    # SIGPIPE ldconfig under `set -o pipefail` and kill the script).
    mapfile -t candidates < <(ldconfig -p 2>/dev/null | awk -v l="$lib" '$1==l {print $NF}')
    src="${candidates[0]:-}"
    if [ -z "$src" ] || [ ! -f "$src" ]; then
      echo "    !! cannot resolve $lib via ldconfig, skipping" >&2
      continue
    fi
    echo "    + $lib"
    cp -L "$src" "$target_dir/$lib"
    while read -r dep; do
      queue+=("$dep")
    done < <(ldd "$src" 2>/dev/null | awk '$2=="=>" && $3 ~ /^\// {print $1}')
  done
}

cp "$DESKTOP_DIR/$ID.desktop" "$APPDIR/$ID.desktop"
cp "$DESKTOP_DIR/$ID.desktop" "$APPDIR/usr/share/applications/"

cp "$ICON_SOURCE" "$APPDIR/$ID.png"
cp "$ICON_SOURCE" "$APPDIR/usr/share/icons/hicolor/512x512/apps/$ID.png"

# appimagetool creates .DirIcon itself when it is missing, but a symlink created
# at pack time carries the pack time. Create it here so it gets the same
# normalised timestamp as everything else (see below).
ln -sf "$ID.png" "$APPDIR/.DirIcon"

cp "$DESKTOP_DIR/$ID.metainfo.xml" "$APPDIR/usr/share/metainfo/"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
SELF=$(readlink -f "$0")
HERE=$(dirname "$SELF")
export APPDIR="$HERE"
# Prefer the bundled libraries (e.g. the libsecret closure) over the host.
export LD_LIBRARY_PATH="$HERE/usr/lib/loveace/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GSETTINGS_SCHEMA_DIR="${GSETTINGS_SCHEMA_DIR:-$HERE/usr/share/glib-2.0/schemas}"
exec "$HERE/usr/lib/loveace/loveace" "$@"
EOF
chmod +x "$APPDIR/AppRun"
chmod +x "$APPDIR/usr/lib/loveace/loveace"
chmod +x "$APPDIR/usr/lib/loveace/lib/"*.so 2>/dev/null || true

# --- Pre-pack assertions ----------------------------------------------------
# The OTA client reads data/flutter_assets/version.json to decide whether an
# update exists. A missing or stale file would silently break update detection
# while still producing a "successful" AppImage, so fail the build instead.
VERSION_JSON="$APPDIR/usr/lib/loveace/data/flutter_assets/version.json"
if [ ! -f "$VERSION_JSON" ]; then
  echo "error: $VERSION_JSON is missing from the Flutter bundle" >&2
  echo "error: refusing to pack an AppImage without version metadata" >&2
  exit 1
fi
python3 - "$VERSION_JSON" "$version" "$build" <<'PY'
import json
import sys

path, expected_version, expected_build = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding='utf-8') as handle:
        data = json.load(handle)
except (OSError, ValueError) as exc:
    raise SystemExit(f'error: cannot parse {path}: {exc}')

actual_version = str(data.get('version', ''))
actual_build = str(data.get('build_number', ''))
if (actual_version, actual_build) != (expected_version, expected_build):
    raise SystemExit(
        f'error: {path} does not match desktop/pubspec.yaml: '
        f'bundle has {actual_version}+{actual_build}, '
        f'pubspec has {expected_version}+{expected_build}'
    )
print(f'==> version.json matches pubspec: {actual_version}+{actual_build}')
PY

# --- Normalise timestamps for a reproducible artifact -----------------------
# mksquashfs records an mtime for every entry, and the AppDir is rebuilt from
# scratch on each run: files copied out of the freshly built Flutter bundle and
# directories created by this script would otherwise carry the build time, so
# rebuilding the same revision produced an AppImage with a different digest.
# Pin every entry to a fixed epoch and export SOURCE_DATE_EPOCH so mksquashfs
# also fixes the filesystem creation time. Default: 2025-11-08T00:00:00Z, the
# release date of the pinned type-2 runtime.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1762560000}"
export SOURCE_DATE_EPOCH
repro_timestamp="$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)"
find "$APPDIR" -exec touch -h -t "$repro_timestamp" {} +

# --- Pack ------------------------------------------------------------------
echo "==> Packing AppImage"
OUT="$OUT_DIR/LoveACE-$version-x86_64.AppImage"
rm -f "$OUT"
APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGE_TOOL" --no-appstream \
  --runtime-file "$RUNTIME_FILE" "$APPDIR" "$OUT"

echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
