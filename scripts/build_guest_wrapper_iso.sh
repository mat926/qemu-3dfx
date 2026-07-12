#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-"$ROOT_DIR/artifacts"}"
ISO_NAME="${ISO_NAME:-qemu-3dfx-guest-wrappers.iso}"
ISO_PATH="${ISO_PATH:-"$ARTIFACT_DIR/$ISO_NAME"}"
BUILD_3DFX="$ROOT_DIR/wrappers/3dfx/build-ci"
BUILD_MESA="$ROOT_DIR/wrappers/mesa/build-ci"
STAGE_DIR="$ARTIFACT_DIR/guest-wrappers/iso-root"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
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

require_cmd bash
require_cmd gendef
require_cmd git
require_cmd make
require_cmd shasum
require_cmd xorriso
require_cmd xxd
require_cmd i686-w64-mingw32-gcc
require_cmd i686-w64-mingw32-dlltool
require_cmd i686-w64-mingw32-windres

rm -rf "$BUILD_3DFX" "$BUILD_MESA" "$STAGE_DIR" "$ISO_PATH" "$ISO_PATH.sha256"
mkdir -p "$BUILD_3DFX" "$BUILD_MESA" "$STAGE_DIR"

echo "Building 3dfx Glide guest wrappers..."
(
  cd "$BUILD_3DFX"
  bash ../../../scripts/conf_wrapper
  make
  make clean
)

echo "Building Mesa/OpenGL guest wrapper..."
(
  cd "$BUILD_MESA"
  bash ../../../scripts/conf_wrapper
  make
  make clean
)

WIN9X="$STAGE_DIR/Win9x-ME"
WINXP="$STAGE_DIR/Win2K-XP"
mkdir -p "$WIN9X" "$WINXP"

for dll in glide.dll glide2x.dll glide3x.dll; do
  copy_required "$BUILD_3DFX/$dll" "$WIN9X/$dll"
  copy_required "$BUILD_3DFX/$dll" "$WINXP/$dll"
done

copy_required "$BUILD_3DFX/fxmemmap.vxd" "$WIN9X/fxmemmap.vxd"
copy_optional "$BUILD_3DFX/glide2x.ovl" "$WIN9X/glide2x.ovl"

copy_required "$BUILD_3DFX/fxptl.sys" "$WINXP/fxptl.sys"
copy_required "$BUILD_3DFX/instdrv.exe" "$WINXP/instdrv.exe"

copy_required "$BUILD_MESA/opengl32.dll" "$WIN9X/opengl32.dll"
copy_required "$BUILD_MESA/opengl32.dll" "$WINXP/opengl32.dll"

write_crlf "$WIN9X/wrapgl32.ext" <<'EOF'
CursorSyncOn,1
EOF

write_crlf "$WINXP/wrapgl32.ext" <<'EOF'
CursorSyncOn,1
EOF

write_crlf "$STAGE_DIR/README.TXT" <<'EOF'
qemu-3dfx guest wrappers
========================

This ISO contains qemu-3dfx guest-side Glide and OpenGL wrappers built by CI.

Folders:

  Win9x-ME   Windows 95, 98, 98 SE, and ME wrappers and install scripts
  Win2K-XP   Windows 2000 and XP wrappers and install scripts

Direct3D notes:

  qemu-3dfx does not provide a native Direct3D driver. Direct3D games can use
  WineD3D DLLs in the game directory together with this ISO's opengl32.dll.
  See Win2K-XP\README_D3D9.TXT for the tested Direct3D 9 wrapper layout.

The Windows wrapper binaries should import msvcrt.dll, not api-ms-win-crt-*.
That keeps them usable on Windows 9x/ME/2000/XP.
EOF

write_crlf "$WIN9X/README.TXT" <<'EOF'
qemu-3dfx wrappers for Windows 9x/ME
====================================

Manual system install:

1. Copy FXMEMMAP.VXD to C:\WINDOWS\SYSTEM.
2. Copy GLIDE.DLL, GLIDE2X.DLL, and GLIDE3X.DLL to C:\WINDOWS\SYSTEM.
3. If GLIDE2X.OVL is present, copy it to C:\WINDOWS.
4. Restart Windows.

Manual OpenGL game install:

1. Copy OPENGL32.DLL into the game's install folder, beside the game EXE.
2. Optionally copy WRAPGL32.EXT into the same folder. This ISO's WRAPGL32.EXT
   enables CursorSyncOn,1 for games that need host cursor sync.

Automatic install scripts:

  INSTALL_SYSTEM.BAT
    Copies the Glide system files into the Windows folder.

  INSTALL_OPENGL_GAME.BAT C:\Path\To\Game
    Copies OPENGL32.DLL and WRAPGL32.EXT into a game folder.

Run INSTALL_SYSTEM.BAT from this Win9x-ME folder on the CD.
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
qemu-3dfx wrappers for Windows 2000/XP
======================================

Manual system install:

1. Copy FXPTL.SYS to %SystemRoot%\system32\drivers.
2. Copy GLIDE.DLL, GLIDE2X.DLL, and GLIDE3X.DLL to %SystemRoot%\system32.
3. Run INSTDRV.EXE as Administrator.
4. Restart Windows.

Manual OpenGL game install:

1. Copy OPENGL32.DLL into the game's install folder, beside the game EXE.
2. Optionally copy WRAPGL32.EXT into the same folder. This ISO's WRAPGL32.EXT
   enables CursorSyncOn,1 for games that need host cursor sync.

Automatic install scripts:

  INSTALL_SYSTEM.BAT
    Copies the Glide system files and runs INSTDRV.EXE.

  INSTALL_OPENGL_GAME.BAT "C:\Path\To\Game"
    Copies OPENGL32.DLL and WRAPGL32.EXT into a game folder.

  INSTALL_D3D9_GAME.BAT "C:\Path\To\Game" "C:\Path\To\WineD3D"
    Copies OPENGL32.DLL, WRAPGL32.EXT, D3D9.DLL, and WINED3D.DLL into a game
    folder. WineD3D DLLs are not included on this ISO.
EOF

write_crlf "$WINXP/README_D3D9.TXT" <<'EOF'
Direct3D 9 games on Windows 2000/XP
===================================

qemu-3dfx accelerates Direct3D games through WineD3D, not through a native
Direct3D driver visible in DXDIAG.

Expected file layout for a Direct3D 9 game:

  GameFolder\Game.exe
  GameFolder\d3d9.dll
  GameFolder\wined3d.dll
  GameFolder\opengl32.dll
  GameFolder\wrapgl32.ext

Tested Windows XP Trackmania Nations ESWC layout:

1. Use WineD3D 1.9.7 d3d9.dll and wined3d.dll.
2. Copy this ISO's opengl32.dll into the game folder.
3. Copy this ISO's wrapgl32.ext into the game folder if the game needs cursor
   sync.
4. Run the game fullscreen if text fields do not receive keyboard input in
   windowed mode.

Do not copy WineD3D d3d9.dll or wined3d.dll into C:\WINDOWS\system32 for this
per-game setup.
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

write_crlf "$WINXP/INSTALL_D3D9_GAME.BAT" <<'EOF'
@echo off
set SRC=%~dp0
if "%~1"=="" goto usage
if "%~2"=="" goto usage
copy /Y "%SRC%OPENGL32.DLL" "%~1\OPENGL32.DLL"
copy /Y "%SRC%WRAPGL32.EXT" "%~1\WRAPGL32.EXT"
copy /Y "%~2\D3D9.DLL" "%~1\D3D9.DLL"
copy /Y "%~2\WINED3D.DLL" "%~1\WINED3D.DLL"
echo Installed qemu-3dfx OpenGL wrapper and WineD3D files into %~1
goto end
:usage
echo Usage: INSTALL_D3D9_GAME.BAT "C:\Path\To\Game" "C:\Path\To\WineD3D"
echo WineD3D folder must contain D3D9.DLL and WINED3D.DLL.
:end
pause
EOF

xorriso -as mkisofs -r -J -V QEMU3DFX_WRAP -o "$ISO_PATH" "$STAGE_DIR"
sha256sum "$ISO_PATH" > "$ISO_PATH.sha256"

echo "Created $ISO_PATH"
echo "Created $ISO_PATH.sha256"
