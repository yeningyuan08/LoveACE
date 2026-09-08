#!/usr/bin/env bash
# Build a Linux AppImage for the LoveACE Flutter desktop app.
#
# Works both locally and on CI (ubuntu-latest). Requires:
#   - flutter (stable, Linux desktop enabled) on PATH
#   - cmake, ninja, clang, pkg-config, gtk+-3.0 dev headers
#   - python3 (+ Pillow) only when regenerating the icon; a prebuilt icon
#     ships in this directory so CI does not need Pillow
#   - network on first run to download appimagetool (cached afterwards)
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

APPIMAGE_TOOL="$SCRIPT_DIR/appimagetool-x86_64.AppImage"
ICON_SOURCE="$SCRIPT_DIR/$ID.png"

# --- Version from pubspec -------------------------------------------------
version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+).*/\1/p' "$DESKTOP_DIR/pubspec.yaml" | head -1)"
if [ -z "$version" ]; then
  echo "error: cannot read version from desktop/pubspec.yaml" >&2
  exit 1
fi
echo "==> LoveACE desktop version: $version"

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

# --- appimagetool (download once, cache beside the script) -----------------
if [ ! -x "$APPIMAGE_TOOL" ]; then
  echo "==> Downloading appimagetool"
  curl -sL --max-time 300 -o "$APPIMAGE_TOOL" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$APPIMAGE_TOOL"
fi

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

# --- Pack ------------------------------------------------------------------
echo "==> Packing AppImage"
OUT="$OUT_DIR/LoveACE-$version-x86_64.AppImage"
rm -f "$OUT"
APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGE_TOOL" --no-appstream "$APPDIR" "$OUT"

echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
