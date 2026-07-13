#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-"$ROOT_DIR/artifacts"}"
ISO_NAME="${ISO_NAME:-qemu-3dfx-guest-wrappers.iso}"
ISO_PATH="${ISO_PATH:-"$ARTIFACT_DIR/$ISO_NAME"}"
WINED3D_BASE_URL="${WINED3D_BASE_URL:-https://downloads.fdossena.com/Projects/WineD3D/Builds}"
WINED3D_INDEX_URL="${WINED3D_INDEX_URL:-$WINED3D_BASE_URL/}"
WINED3D_INDEX_FALLBACK_URL="${WINED3D_INDEX_FALLBACK_URL:-https://downloads.fdossena.com/geth.php?r=wined3d-all}"
WINED3D_RECOMMENDED_URL="${WINED3D_RECOMMENDED_URL:-https://downloads.fdossena.com/geth.php?r=wined3d-recommended}"
WINED3D_ARCHIVES="${WINED3D_ARCHIVES:-}"
WINED3D_DEFAULT_VERSION="${WINED3D_DEFAULT_VERSION:-}"
WINED3D_SKIP_UCRT="${WINED3D_SKIP_UCRT:-1}"
BUILD_3DFX="$ROOT_DIR/wrappers/3dfx/build-ci"
BUILD_MESA="$ROOT_DIR/wrappers/mesa/build-ci"
STAGE_DIR="$ARTIFACT_DIR/guest-wrappers/iso-root"
WINED3D_CACHE_DIR="$ROOT_DIR/.cache/wined3d"
WINED3D_STAGED_IDS=()
WINED3D_SKIPPED_IDS=()

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

verify_xp_runtime_imports() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "Missing expected Windows PE file: $file" >&2
    exit 1
  fi
  if has_modern_crt_imports "$file"; then
    echo "Modern UCRT import found in $file; this is not compatible with Windows 9x/2000/XP." >&2
    objdump -p "$file" | grep -Ei 'DLL Name: (api-ms-win-crt|ucrtbase\.dll)' >&2 || true
    exit 1
  fi
}

write_crlf() {
  local dst="$1"
  mkdir -p "$(dirname "$dst")"
  sed 's/$/\r/' > "$dst"
}

archive_to_wined3d_id() {
  local archive="$1"
  archive="${archive##*/}"
  archive="${archive#WineD3DForWindows_}"
  archive="${archive%.zip}"
  printf '%s\n' "$archive"
}

discover_wined3d_archives() {
  local index_file="$ARTIFACT_DIR/guest-wrappers/wined3d-index.html"
  local archive_list="$ARTIFACT_DIR/guest-wrappers/wined3d-archives.txt"
  local archive_count

  if [[ -n "$WINED3D_ARCHIVES" ]]; then
    printf '%s\n' $WINED3D_ARCHIVES
    return
  fi

  mkdir -p "$(dirname "$index_file")"

  echo "Discovering WineD3D archives from $WINED3D_INDEX_URL" >&2
  curl -fsLA 'Mozilla/5.0' "$WINED3D_INDEX_URL" -o "$index_file"

  grep -Eo 'WineD3DForWindows_[^"<>[:space:]]+\.zip' "$index_file" |
    awk '!seen[$0]++' |
    grep -v 'x86_64' > "$archive_list" || true

  archive_count="$(wc -l < "$archive_list")"

  if [[ "$archive_count" -eq 0 && -n "$WINED3D_INDEX_FALLBACK_URL" ]]; then
    echo "No 32-bit WineD3D archives found; retrying discovery from $WINED3D_INDEX_FALLBACK_URL" >&2
    curl -fsLA 'Mozilla/5.0' "$WINED3D_INDEX_FALLBACK_URL" -o "$index_file"
    grep -Eo 'WineD3DForWindows_[^"<>[:space:]]+\.zip' "$index_file" |
      awk '!seen[$0]++' |
      grep -v 'x86_64' > "$archive_list" || true
    archive_count="$(wc -l < "$archive_list")"
  fi

  echo "Discovered $archive_count 32-bit WineD3D archive(s)." >&2
  if [[ "$archive_count" -gt 0 ]]; then
    sed -n '1,10p' "$archive_list" >&2
  fi

  cat "$archive_list"
}

resolve_recommended_wined3d_id() {
  curl -fsIL "$WINED3D_RECOMMENDED_URL" |
    sed -nE 's/^[Ll]ocation:[[:space:]]*.*WineD3DForWindows_([^/[:space:]]+)\.zip.*/\1/p' |
    tr -d '\r' |
    tail -n 1
}

download_wined3d_archive() {
  local archive="$1"
  local url="$WINED3D_BASE_URL/$archive"
  local zip_path="$WINED3D_CACHE_DIR/$archive"

  mkdir -p "$WINED3D_CACHE_DIR"
  if [[ ! -f "$zip_path" ]]; then
    echo "Downloading $archive..." >&2
    curl -fL --retry 3 --retry-delay 2 -o "$zip_path.tmp" "$url"
    mv "$zip_path.tmp" "$zip_path"
  fi

  printf '%s\n' "$zip_path"
}

find_extracted_file() {
  local src_dir="$1"
  local name="$2"
  find "$src_dir" -type f -iname "$name" -print -quit
}

copy_extracted_optional() {
  local src_dir="$1"
  local name="$2"
  local dst_dir="$3"
  local src
  src="$(find_extracted_file "$src_dir" "$name")"
  if [[ -n "$src" ]]; then
    install -D -m 0644 "$src" "$dst_dir/$(basename "$src")"
    return 0
  fi
  return 1
}

copy_extracted_required() {
  local src_dir="$1"
  local name="$2"
  local dst_dir="$3"
  if ! copy_extracted_optional "$src_dir" "$name" "$dst_dir"; then
    echo "Missing required WineD3D file $name in $src_dir" >&2
    return 1
  fi
}

has_modern_crt_imports() {
  local file="$1"
  objdump -p "$file" | grep -Eiq 'DLL Name: (api-ms-win-crt|ucrtbase\.dll)'
}

stage_wined3d_archive() {
  local archive="$1"
  local zip_path="$2"
  local id
  local extract_dir
  local dst
  local file
  local frontend_count=0
  local readme
  id="$(archive_to_wined3d_id "$archive")"
  extract_dir="$ARTIFACT_DIR/guest-wrappers/wined3d-extract-$id"
  dst="$WINXP/Direct3D/WineD3D-$id"

  rm -rf "$extract_dir" "$dst"
  mkdir -p "$extract_dir" "$dst"
  bsdtar -xf "$zip_path" -C "$extract_dir"

  copy_extracted_required "$extract_dir" "wined3d.dll" "$dst"

  for file in \
    ddraw.dll \
    d3d8.dll \
    d3d9.dll \
    d3d10.dll \
    d3d10_1.dll \
    d3d10core.dll \
    d3d11.dll \
    dxgi.dll; do
    if copy_extracted_optional "$extract_dir" "$file" "$dst"; then
      frontend_count=$((frontend_count + 1))
    fi
  done

  copy_extracted_optional "$extract_dir" "libwine.dll" "$dst" || true

  readme="$(find "$extract_dir" -type f -iname '*README*.txt' -print -quit)"
  if [[ -n "$readme" ]]; then
    install -D -m 0644 "$readme" "$dst/README.txt"
  fi

  if [[ "$frontend_count" -eq 0 ]]; then
    echo "No Direct3D or DirectDraw frontend DLLs found in $archive" >&2
    rm -rf "$dst"
    return 1
  fi

  for file in "$dst"/*.dll; do
    if has_modern_crt_imports "$file"; then
      if [[ "$WINED3D_SKIP_UCRT" == "1" ]]; then
        echo "Skipping $archive: $(basename "$file") imports api-ms-win-crt or ucrtbase.dll." >&2
        rm -rf "$dst"
        WINED3D_SKIPPED_IDS+=("$id")
        return 0
      fi
      verify_xp_runtime_imports "$file"
    fi
  done

  write_crlf "$dst/SOURCE.TXT" <<EOF
WineD3D for Windows $id
=======================

Downloaded from:
  $WINED3D_BASE_URL/$archive

Project page:
  https://fdossena.com/?p=wined3d/index.frag

License:
  GNU LGPL version 2 or newer, as published by the WineD3D for Windows project.

The original package README is included as README.TXT in this folder.
EOF

  WINED3D_STAGED_IDS+=("$id")
}

require_cmd awk
require_cmd bash
require_cmd bsdtar
require_cmd curl
require_cmd gendef
require_cmd git
require_cmd grep
require_cmd make
require_cmd objdump
require_cmd shasum
require_cmd sha256sum
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

echo "Verifying Windows XP compatible runtime imports..."
for pe_file in \
  "$BUILD_3DFX/glide.dll" \
  "$BUILD_3DFX/glide2x.dll" \
  "$BUILD_3DFX/glide3x.dll" \
  "$BUILD_3DFX/instdrv.exe" \
  "$BUILD_MESA/opengl32.dll"; do
  verify_xp_runtime_imports "$pe_file"
done

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

while IFS= read -r wined3d_archive; do
  [[ -n "$wined3d_archive" ]] || continue
  stage_wined3d_archive "$wined3d_archive" "$(download_wined3d_archive "$wined3d_archive")"
done < <(discover_wined3d_archives)

if [[ "${#WINED3D_STAGED_IDS[@]}" -eq 0 ]]; then
  echo "No WineD3D archives were staged." >&2
  exit 1
fi

if [[ -z "$WINED3D_DEFAULT_VERSION" ]]; then
  WINED3D_DEFAULT_VERSION="$(resolve_recommended_wined3d_id || true)"
fi

if [[ -z "$WINED3D_DEFAULT_VERSION" ]]; then
  WINED3D_DEFAULT_VERSION="${WINED3D_STAGED_IDS[0]}"
fi

if [[ ! -d "$WINXP/Direct3D/WineD3D-$WINED3D_DEFAULT_VERSION" ]]; then
  echo "Default WineD3D version $WINED3D_DEFAULT_VERSION was not staged; using ${WINED3D_STAGED_IDS[0]}." >&2
  WINED3D_DEFAULT_VERSION="${WINED3D_STAGED_IDS[0]}"
fi

{
  for wined3d_id in "${WINED3D_STAGED_IDS[@]}"; do
    printf '%s\n' "$wined3d_id"
  done
} | sed 's/$/\r/' > "$WINXP/Direct3D/VERSIONS.TXT"

WINED3D_VERSION_COUNT="${#WINED3D_STAGED_IDS[@]}"
WINED3D_SKIPPED_COUNT="${#WINED3D_SKIPPED_IDS[@]}"

if [[ "$WINED3D_SKIPPED_COUNT" -gt 0 ]]; then
  {
    printf 'The following 32-bit WineD3D package(s) were discovered but not packaged.\n'
    printf 'They import api-ms-win-crt-* or ucrtbase.dll and are not suitable for a stock Windows XP guest.\n\n'
    for wined3d_id in "${WINED3D_SKIPPED_IDS[@]}"; do
      printf '%s\n' "$wined3d_id"
    done
  } | sed 's/$/\r/' > "$WINXP/Direct3D/SKIPPED_UCRT.TXT"
fi

write_crlf "$WINXP/Direct3D/INSTALL_ALL_VERSIONS_WARNING.TXT" <<EOF
This ISO includes $WINED3D_VERSION_COUNT XP-compatible 32-bit WineD3D for
Windows package(s).

Use INSTALL_D3D_GAME.BAT from the parent Win2K-XP folder to copy one selected
WineD3D version into a game's install folder. Do not copy every WineD3D version
into the same game folder at the same time.

If present, SKIPPED_UCRT.TXT lists newer packages that were not bundled because
they import api-ms-win-crt-* or ucrtbase.dll.
EOF

write_crlf "$STAGE_DIR/README.TXT" <<'EOF'
qemu-3dfx guest wrappers
========================

This ISO contains qemu-3dfx guest-side Glide and OpenGL wrappers built by CI.

Folders:

  Win9x-ME   Windows 95, 98, 98 SE, and ME wrappers and install scripts
  Win2K-XP   Windows 2000 and XP wrappers and install scripts

Direct3D notes:

  qemu-3dfx does not provide a native Direct3D driver visible in DXDIAG.
  Direct3D games can use the included WineD3D DLLs in the game directory
  together with this ISO's opengl32.dll. See Win2K-XP\README_D3D.TXT.

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

  INSTALL_D3D_GAME.BAT "C:\Path\To\Game" [WineD3D-Version]
    Copies OPENGL32.DLL, WRAPGL32.EXT, and the selected WineD3D Direct3D DLLs
    into a game folder. See Direct3D\VERSIONS.TXT for bundled versions.

  INSTALL_D3D9_GAME.BAT "C:\Path\To\Game" [WineD3D-Version]
    Compatibility alias for INSTALL_D3D_GAME.BAT.
EOF

write_crlf "$WINXP/README_D3D.TXT" <<EOF
Direct3D games on Windows 2000/XP
=================================

qemu-3dfx accelerates Direct3D games through WineD3D, not through a native
Direct3D driver visible in DXDIAG.

This ISO includes $WINED3D_VERSION_COUNT XP-compatible 32-bit WineD3D for
Windows package(s) discovered from the upstream all-versions archive. It
excludes x86_64 packages because this Windows XP VM is 32-bit.

Skipped UCRT-based package count:

  $WINED3D_SKIPPED_COUNT

Bundled versions are listed in:

  Direct3D\VERSIONS.TXT

If present, skipped versions are listed in:

  Direct3D\SKIPPED_UCRT.TXT

Default version used by the install scripts:

  WineD3D-$WINED3D_DEFAULT_VERSION

Expected file layout for a Direct3D game:

  GameFolder\Game.exe
  GameFolder\ddraw.dll
  GameFolder\d3d8.dll
  GameFolder\d3d9.dll
  GameFolder\wined3d.dll
  GameFolder\libwine.dll
  GameFolder\opengl32.dll
  GameFolder\wrapgl32.ext

Tested Windows XP Trackmania Nations ESWC layout:

1. Use WineD3D 1.9.7 d3d9.dll and wined3d.dll.
2. Copy libwine.dll from the same WineD3D release.
3. Copy this ISO's opengl32.dll into the game folder.
4. Copy this ISO's wrapgl32.ext into the game folder if the game needs cursor
   sync.
5. Run the game fullscreen if text fields do not receive keyboard input in
   windowed mode.

The INSTALL_D3D_GAME.BAT script copies all bundled WineD3D DLLs from the
selected release into a game folder. Depending on the selected WineD3D release,
that can include DirectDraw, Direct3D 8, Direct3D 9, Direct3D 10/11, DXGI,
wined3d.dll, and libwine.dll. Windows XP games normally use DirectDraw,
Direct3D 8, or Direct3D 9.

Do not copy WineD3D DLLs into C:\WINDOWS\system32 for this per-game setup.
EOF

write_crlf "$WINXP/README_D3D9.TXT" <<'EOF'
This file is kept for compatibility with older ISO instructions.

Use README_D3D.TXT and INSTALL_D3D_GAME.BAT for Direct3D game installs.
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

write_crlf "$WINXP/INSTALL_D3D_GAME.BAT" <<EOF
@echo off
set SRC=%~dp0
set VERSION=$WINED3D_DEFAULT_VERSION
if "%~1"=="" goto usage
if not "%~2"=="" set VERSION=%~2
set D3DSRC=%SRC%Direct3D\WineD3D-%VERSION%
if not exist "%D3DSRC%\WINED3D.DLL" goto missing
copy /Y "%SRC%OPENGL32.DLL" "%~1\OPENGL32.DLL"
copy /Y "%SRC%WRAPGL32.EXT" "%~1\WRAPGL32.EXT"
for %%F in (DDRAW.DLL D3D8.DLL D3D9.DLL D3D10.DLL D3D10CORE.DLL D3D11.DLL DXGI.DLL WINED3D.DLL LIBWINE.DLL) do if exist "%D3DSRC%\%%F" copy /Y "%D3DSRC%\%%F" "%~1\%%F"
echo Installed qemu-3dfx OpenGL wrapper and WineD3D %VERSION% files into %~1
goto end
:missing
echo WineD3D %VERSION% was not found at:
echo %D3DSRC%
echo.
echo Available bundled versions are under:
echo %SRC%Direct3D
goto end
:usage
echo Usage: INSTALL_D3D_GAME.BAT "C:\Path\To\Game" [WineD3D-Version]
echo Default WineD3D version: $WINED3D_DEFAULT_VERSION
:end
pause
EOF

write_crlf "$WINXP/INSTALL_D3D9_GAME.BAT" <<'EOF'
@echo off
set SRC=%~dp0
call "%SRC%INSTALL_D3D_GAME.BAT" %*
EOF

xorriso -as mkisofs -r -J -V QEMU3DFX_WRAP -o "$ISO_PATH" "$STAGE_DIR"
sha256sum "$ISO_PATH" > "$ISO_PATH.sha256"

echo "Created $ISO_PATH"
echo "Created $ISO_PATH.sha256"
