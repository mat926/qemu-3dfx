#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-"$ROOT_DIR/artifacts"}"
ISO_NAME="${ISO_NAME:-VMADDONS.iso}"
ISO_LABEL="${ISO_LABEL:-VMADDONS}"
ISO_PATH="${ISO_PATH:-"$ARTIFACT_DIR/$ISO_NAME"}"
WORK_DIR="$ARTIFACT_DIR/vmaddons"
STAGE_DIR="$WORK_DIR/iso-root"
BUILD_3DFX="$ROOT_DIR/wrappers/3dfx/build-ci"
BUILD_MESA="$ROOT_DIR/wrappers/mesa/build-ci"
OBJDUMP="${OBJDUMP:-}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

select_objdump() {
  if [[ -n "$OBJDUMP" ]]; then
    require_cmd "$OBJDUMP"
    return
  fi

  if command -v i686-w64-mingw32-objdump >/dev/null 2>&1; then
    OBJDUMP="i686-w64-mingw32-objdump"
  elif command -v objdump >/dev/null 2>&1; then
    OBJDUMP="objdump"
  else
    echo "Missing required command: i686-w64-mingw32-objdump or objdump" >&2
    exit 1
  fi
}

copy_required() {
  local src="$1"
  local dst="$2"

  if [[ ! -f "$src" ]]; then
    echo "Missing expected build artifact: $src" >&2
    exit 1
  fi

  install -D -m 0644 "$src" "$dst"
}

copy_optional() {
  local src="$1"
  local dst="$2"

  if [[ -f "$src" ]]; then
    install -D -m 0644 "$src" "$dst"
  fi
}

write_crlf() {
  local dst="$1"

  mkdir -p "$(dirname "$dst")"
  sed 's/$/\r/' > "$dst"
}

verify_no_modern_crt_imports() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    echo "Missing expected Windows file: $file" >&2
    exit 1
  fi

  if "$OBJDUMP" -p "$file" 2>/dev/null | grep -Eiq 'DLL Name: (api-ms-win-crt|ucrtbase\.dll)'; then
    echo "Modern UCRT import found in $file; this is not compatible with Windows 9x/ME/2000/XP." >&2
    "$OBJDUMP" -p "$file" | grep -Ei 'DLL Name: (api-ms-win-crt|ucrtbase\.dll)' >&2 || true
    exit 1
  fi
}

build_wrapper() {
  local label="$1"
  local build_dir="$2"

  echo "Building $label guest wrappers..."
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  (
    cd "$build_dir"
    bash ../../../scripts/conf_wrapper
    make
    make clean
  )
}

for cmd in \
  bash \
  gendef \
  git \
  make \
  shasum \
  sha256sum \
  xorriso \
  xxd \
  i686-w64-mingw32-gcc \
  i686-w64-mingw32-dlltool \
  i686-w64-mingw32-windres; do
  require_cmd "$cmd"
done
select_objdump

rm -rf "$BUILD_3DFX" "$BUILD_MESA" "$WORK_DIR" "$ISO_PATH" "$ISO_PATH.sha256"
rm -f "$ARTIFACT_DIR/qemu-3dfx-guest-wrappers.iso" "$ARTIFACT_DIR/qemu-3dfx-guest-wrappers.iso.sha256"
mkdir -p "$ARTIFACT_DIR" "$STAGE_DIR"

# Mirrors the upstream README flow:
#   cd wrappers/<name>; mkdir build; cd build; bash ../../../scripts/conf_wrapper; make && make clean
build_wrapper "3dfx Glide" "$BUILD_3DFX"
build_wrapper "Mesa/OpenGL" "$BUILD_MESA"

echo "Verifying Windows guest wrapper imports..."
for pe_file in \
  "$BUILD_3DFX/glide.dll" \
  "$BUILD_3DFX/glide2x.dll" \
  "$BUILD_3DFX/glide3x.dll" \
  "$BUILD_3DFX/instdrv.exe" \
  "$BUILD_3DFX/fxptl.sys" \
  "$BUILD_MESA/opengl32.dll"; do
  verify_no_modern_crt_imports "$pe_file"
done

WIN9X="$STAGE_DIR/Win9x-ME"
WINXP="$STAGE_DIR/Win2K-XP"
mkdir -p "$WIN9X" "$WINXP"

for dll in glide.dll glide2x.dll glide3x.dll; do
  copy_required "$BUILD_3DFX/$dll" "$WIN9X/${dll^^}"
  copy_required "$BUILD_3DFX/$dll" "$WINXP/${dll^^}"
done

copy_required "$BUILD_3DFX/fxmemmap.vxd" "$WIN9X/FXMEMMAP.VXD"
copy_optional "$BUILD_3DFX/glide2x.ovl" "$WIN9X/GLIDE2X.OVL"

copy_required "$BUILD_3DFX/fxptl.sys" "$WINXP/FXPTL.SYS"
copy_required "$BUILD_3DFX/instdrv.exe" "$WINXP/INSTDRV.EXE"

copy_required "$BUILD_MESA/opengl32.dll" "$WIN9X/OPENGL32.DLL"
copy_required "$BUILD_MESA/opengl32.dll" "$WINXP/OPENGL32.DLL"

write_crlf "$WIN9X/WRAPGL32.EXT" <<'EOF'
CursorSyncOn,1
EOF

write_crlf "$WINXP/WRAPGL32.EXT" <<'EOF'
CursorSyncOn,1
EOF

GIT_REVISION="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

write_crlf "$STAGE_DIR/README.TXT" <<EOF
VMADDONS for qemu-3dfx
=====================

This ISO contains qemu-3dfx guest-side wrappers built from this repository.

Repository revision:
  $GIT_REVISION

Folders:
  Win9x-ME   Windows 95, 98, 98 SE, and ME guest files
  Win2K-XP   Windows 2000 and XP guest files

The ISO contains the Glide system wrappers and the OpenGL per-game wrapper.
It does not contain QEMU host binaries.
EOF

write_crlf "$WIN9X/README.TXT" <<'EOF'
qemu-3dfx VMADDONS for Windows 9x/ME
====================================

Manual Glide install:

1. Copy FXMEMMAP.VXD to C:\WINDOWS\SYSTEM.
2. Copy GLIDE.DLL, GLIDE2X.DLL, and GLIDE3X.DLL to C:\WINDOWS\SYSTEM.
3. If GLIDE2X.OVL is present, copy it to C:\WINDOWS.
4. Restart Windows.

Manual OpenGL game install:

1. Copy OPENGL32.DLL into the game's install folder, beside the game EXE.
2. Copy WRAPGL32.EXT into the same folder if the game needs cursor sync.

Automatic scripts:

  INSTALL_SYSTEM.BAT
    Copies the Glide system files into the Windows folder.

  INSTALL_OPENGL_GAME.BAT C:\Path\To\Game
    Copies OPENGL32.DLL and WRAPGL32.EXT into a game folder.
EOF

write_crlf "$WIN9X/INSTALL_SYSTEM.BAT" <<'EOF'
@echo off
if "%windir%"=="" goto nowindir
echo Installing qemu-3dfx Glide files for Windows 9x/ME...
copy /Y FXMEMMAP.VXD "%windir%\SYSTEM\FXMEMMAP.VXD"
copy /Y GLIDE.DLL "%windir%\SYSTEM\GLIDE.DLL"
copy /Y GLIDE2X.DLL "%windir%\SYSTEM\GLIDE2X.DLL"
copy /Y GLIDE3X.DLL "%windir%\SYSTEM\GLIDE3X.DLL"
if exist GLIDE2X.OVL copy /Y GLIDE2X.OVL "%windir%\GLIDE2X.OVL"
echo Done. Restart Windows before testing Glide games.
goto end
:nowindir
echo WINDIR is not set. Copy the files manually; see README.TXT.
:end
pause
EOF

write_crlf "$WIN9X/INSTALL_OPENGL_GAME.BAT" <<'EOF'
@echo off
if "%1"=="" goto usage
copy /Y OPENGL32.DLL "%1\OPENGL32.DLL"
copy /Y WRAPGL32.EXT "%1\WRAPGL32.EXT"
echo Installed qemu-3dfx OpenGL wrapper into %1
goto end
:usage
echo Usage: INSTALL_OPENGL_GAME.BAT C:\Path\To\Game
:end
pause
EOF

write_crlf "$WINXP/README.TXT" <<'EOF'
qemu-3dfx VMADDONS for Windows 2000/XP
======================================

Manual Glide install:

1. Copy FXPTL.SYS to %SystemRoot%\system32\drivers.
2. Copy GLIDE.DLL, GLIDE2X.DLL, and GLIDE3X.DLL to %SystemRoot%\system32.
3. Run INSTDRV.EXE as Administrator.
4. Restart Windows.

Manual OpenGL game install:

1. Copy OPENGL32.DLL into the game's install folder, beside the game EXE.
2. Copy WRAPGL32.EXT into the same folder if the game needs cursor sync.

Automatic scripts:

  INSTALL_SYSTEM.BAT
    Copies the Glide system files and runs INSTDRV.EXE.

  INSTALL_OPENGL_GAME.BAT "C:\Path\To\Game"
    Copies OPENGL32.DLL and WRAPGL32.EXT into a game folder.
EOF

write_crlf "$WINXP/INSTALL_SYSTEM.BAT" <<'EOF'
@echo off
set SRC=%~dp0
if "%SystemRoot%"=="" goto nowinroot
echo Installing qemu-3dfx Glide files for Windows 2000/XP...
copy /Y "%SRC%FXPTL.SYS" "%SystemRoot%\system32\drivers\FXPTL.SYS"
copy /Y "%SRC%GLIDE.DLL" "%SystemRoot%\system32\GLIDE.DLL"
copy /Y "%SRC%GLIDE2X.DLL" "%SystemRoot%\system32\GLIDE2X.DLL"
copy /Y "%SRC%GLIDE3X.DLL" "%SystemRoot%\system32\GLIDE3X.DLL"
"%SRC%INSTDRV.EXE"
echo Done. Restart Windows before testing Glide games.
goto end
:nowinroot
echo SystemRoot is not set. Copy the files manually; see README.TXT.
:end
pause
EOF

write_crlf "$WINXP/INSTALL_OPENGL_GAME.BAT" <<'EOF'
@echo off
set SRC=%~dp0
if "%~1"=="" goto usage
copy /Y "%SRC%OPENGL32.DLL" "%~1\OPENGL32.DLL"
copy /Y "%SRC%WRAPGL32.EXT" "%~1\WRAPGL32.EXT"
echo Installed qemu-3dfx OpenGL wrapper into %~1
goto end
:usage
echo Usage: INSTALL_OPENGL_GAME.BAT "C:\Path\To\Game"
:end
pause
EOF

xorriso -as mkisofs -r -J -V "$ISO_LABEL" -o "$ISO_PATH" "$STAGE_DIR"
sha256sum "$ISO_PATH" > "$ISO_PATH.sha256"

echo "Created $ISO_PATH"
echo "Created $ISO_PATH.sha256"
