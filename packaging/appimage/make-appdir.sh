#!/bin/bash
# Assemble Deskemy.AppDir — step 2 of the AppImage build (README.md next to
# this script has the full three-step recipe; step 1 is `cargo build
# --release`, step 3 is appimagetool, which must run as root).
#
# Runs inside the Fedora build box (distrobox `deskemy-build`); it only
# reads the system libmpv and writes into the checkout, so any distro with
# libmpv + binutils works. Output: <repo>/Deskemy.AppDir (gitignored).
#
# Bundling rules:
#   * Include: everything in the binary's ldd closure, plus libmpv's closure
#     (libmpv is dlopen'd by the FFI so it never appears in the binary's own
#     ldd output — this is the whole reason libmpv must be added by hand).
#   * Exclude: glibc/ld-linux + libstdc++/libgcc_s (host provides them; a
#     bundled libstdc++ fights system mesa), and GPU drivers (libGL/EGL/gbm/
#     drm) which must match the host kernel. GL and wayland/xkbcommon are
#     dlopen'd by Skia/winit and always present on the target desktop.
set -euo pipefail
LIST=$(mktemp)
trap 'rm -f "$LIST"; echo "FAILED at line $LINENO (rc=$?)" >&2' ERR
trap 'rm -f "$LIST"' EXIT

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN=$REPO/app/target/release/deskemy
OUT=$REPO/Deskemy.AppDir
ICON=$REPO/app-icon.png

# libmpv.so.2 lives in the plain libdir on Fedora, in a multiarch triplet
# dir on Debian/Ubuntu.
LIBMPV=
for p in /usr/lib64/libmpv.so.2 /usr/lib/libmpv.so.2 /usr/lib/x86_64-linux-gnu/libmpv.so.2; do
  if [ -e "$p" ]; then LIBMPV=$(readlink -f "$p"); break; fi
done

[ -f "$BIN" ] || { echo "missing release binary: $BIN (run cargo build --release first)"; exit 1; }
[ -f "$LIBMPV" ] || { echo "missing libmpv.so.2 (looked in /usr/lib64, /usr/lib, /usr/lib/x86_64-linux-gnu)"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/usr/bin" "$OUT/usr/lib" \
         "$OUT/usr/share/applications" \
         "$OUT/usr/share/icons/hicolor/1024x1024/apps"

# ---- 1. the binary (drop symtab/debug; 69MB -> smaller) ----
cp "$BIN" "$OUT/usr/bin/deskemy"
strip --strip-unneeded "$OUT/usr/bin/deskemy" 2>/dev/null || true

# ---- 2. library closure ----
BLACKLIST='/(ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libgcc_s|libstdc\+\+|libGL\.so|libEGL\.so|libGLX|libglapi|libgbm|libdrm|libgallium|libOpenGL|libnss_|libresolv|libutil\.so|libcrypt|libselinux)'
closure() { ldd "$1" 2>/dev/null | awk '$2=="=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}'; }

{ closure "$BIN"; closure "$LIBMPV"; } | sort -u \
  | grep -vE "$BLACKLIST" | grep -E "^/" > "$LIST" || true

COUNT=$(grep -c . "$LIST" || true)
if [ "${COUNT:-0}" -lt 5 ]; then
  echo "ERROR: closure came back nearly empty (got $COUNT libs) — ldd parse failed"
  echo "--- raw ldd of binary ---"; ldd "$BIN" | head -10
  exit 1
fi

while read -r lib; do
  if [ -e "$lib" ]; then
    cp -L "$lib" "$OUT/usr/lib/"
  else
    echo "warn: skipped missing $lib"
  fi
done < "$LIST"

# libmpv itself: dlopen'd by deskemy-core (never in the binary's ldd), so add
# it by hand. readlink -f resolved the SONAME symlink to libmpv.so.2.5.0, so
# copy the real file and recreate the libmpv.so.2 name the FFI looks for.
MPV_REAL=$(basename "$LIBMPV")
cp -L "$LIBMPV" "$OUT/usr/lib/$MPV_REAL"
ln -sfn "$MPV_REAL" "$OUT/usr/lib/libmpv.so.2"

if [ ! -e "$OUT/usr/lib/libmpv.so.2" ]; then
  echo "ERROR: libmpv.so.2 missing from AppDir — playback would fail"
  exit 1
fi

echo "=== bundled $(ls "$OUT/usr/lib" | wc -l) libs, $(du -sh "$OUT/usr/lib" | cut -f1) ==="
# sed reads their whole input (unlike `head`, which can SIGPIPE `ls` under pipefail)
ls "$OUT/usr/lib" | sed -n '1,50p' || true
echo "=== sanity: libmpv present? ==="
ls -la "$OUT/usr/lib/libmpv.so.2"

# ---- 3. AppRun ----
cat > "$OUT/AppRun" <<'APPRUN'
#!/bin/sh
# Deskemy AppRun: point the loader and the libmpv FFI at the bundled copy.
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# deskemy-core looks for libmpv next to the exe, then via bare-name dlopen
# (which honours LD_LIBRARY_PATH); pin the exact file for good measure.
export DESKEMY_LIBMPV="${DESKEMY_LIBMPV:-$HERE/usr/lib/libmpv.so.2}"
exec "$HERE/usr/bin/deskemy" "$@"
APPRUN
chmod +x "$OUT/AppRun"

# ---- 4. desktop entry ----
DESKTOP='[Desktop Entry]
Type=Application
Name=Deskemy
GenericName=Course Player
Comment=Play and track offline video courses
Exec=deskemy
Icon=deskemy
Terminal=false
Categories=AudioVideo;Video;Player;Education;
Keywords=video;course;lecture;player;mpv;
StartupWMClass=deskemy
'
printf '%s' "$DESKTOP" > "$OUT/deskemy.desktop"
printf '%s' "$DESKTOP" > "$OUT/usr/share/applications/deskemy.desktop"

# ---- 5. icon (root-level name must match Icon= above) ----
cp "$ICON" "$OUT/deskemy.png"
cp "$ICON" "$OUT/usr/share/icons/hicolor/1024x1024/apps/deskemy.png"
ln -sf deskemy.png "$OUT/.DirIcon"

echo "=== AppDir ==="
du -sh "$OUT"
find "$OUT" -maxdepth 2 -not -path "*/usr/lib/*" | sort
