# Windows XP qemu-3dfx on Arch Linux with libvirt

This note records a working setup for a Windows XP VM using qemu-3dfx on an
Arch Linux host. It is intended for local builds launched through libvirt's
`qemu:///system` connection.

## Host build notes

Build qemu-3dfx from the repository README, then use the patched Mesa host
context in the QEMU build:

```meson
i386_system_ss.add(files(
  'mesagl_blit.c',
  'mesagl_impl.c',
  'mesapt_mm.c',
  'mglcntx_sdlgl.c',
  'mglcntx_mingw.c',
  'mglmapbo.c',
  'mglvarry.c',
))
```

On Linux this keeps qemu-3dfx's Mesa pass-through on the SDL OpenGL context
path. With libvirt, run the VM through SDL on X11:

```xml
<qemu:commandline>
  <qemu:arg value='-display'/>
  <qemu:arg value='sdl,window-close=off'/>
  <qemu:env name='SDL_VIDEODRIVER' value='x11'/>
</qemu:commandline>
```

Do not add `gl=on` to the SDL display string for this setup. The qemu-3dfx
Mesa device creates and manages the needed SDL OpenGL context itself.

## XP-compatible wrapper builds

Current Arch MinGW may default to the Universal CRT. Windows XP does not ship
the `api-ms-win-crt-*` DLLs, so the guest-side Windows wrappers should be built
against the old system CRT:

```make
CFLAGS+=-mcrtdll=msvcrt-os
```

This applies to both:

```text
wrappers/3dfx/src/Makefile.in
wrappers/3dfx/drv/Makefile
wrappers/mesa/src/Makefile.in
```

After building, verify the guest DLLs with:

```sh
i686-w64-mingw32-objdump -p opengl32.dll | grep 'DLL Name'
```

An XP-compatible build should import `msvcrt.dll`, not `api-ms-win-crt-*`.

## Guest wrapper install

For Windows 2000/XP:

1. Copy `fxptl.sys` to `%SystemRoot%\system32\drivers`.
2. Copy `glide.dll`, `glide2x.dll`, and `glide3x.dll` to `%SystemRoot%\system32`.
3. Run `instdrv.exe` as Administrator.
4. Copy `opengl32.dll` beside each OpenGL or WineD3D-wrapped game executable.

For Direct3D games, do not rely on `dxdiag` to report hardware Direct3D. The
expected path is:

```text
game d3d9 -> WineD3D d3d9.dll/wined3d.dll -> qemu-3dfx opengl32.dll -> host OpenGL
```

For Trackmania Nations ESWC on XP, WineD3D `1.9.7` was the best tested version.
Copy these files into the Trackmania install folder, beside `TmNationsESWC.exe`:

```text
d3d9.dll
wined3d.dll
opengl32.dll
```

Do not copy WineD3D DLLs into `C:\WINDOWS\system32` for this setup.

## Cursor sync

The Mesa wrapper reads `wrapgl32.ext` from the game executable directory.
Normally color cursor sync is enabled only when the Windows display adapter
reports as `QEMU Bochs`. For libvirt `vga` or other display choices, place this
file beside the game executable:

```text
CursorSyncOn,1
```

This forces qemu-3dfx cursor sync for games that hide the Win32 cursor and
expect the wrapper/host display path to render it.

## Recommended libvirt devices

Useful baseline for Windows XP:

```xml
<cpu mode='custom' match='exact' check='none'>
  <model fallback='allow'>core2duo</model>
</cpu>

<video>
  <model type='vga' vram='16384' heads='1' primary='yes'/>
</video>

<sound model='ac97'/>
<audio id='1' type='pipewire' runtimeDir='/run/user/1000'/>

<input type='mouse' bus='ps2'/>
<input type='keyboard' bus='ps2'/>
```

Use a USB 2.0 EHCI controller if needed for removable media or other USB
devices, but avoid a USB tablet for old DirectInput games. A USB tablet gives
seamless host/guest pointer integration, but Trackmania's menu input worked
more reliably with PS/2 relative mouse input.

For Trackmania text fields, run the game in fullscreen mode. Fullscreen forces
SDL's grab path, which gives the game keyboard input reliably. Release the QEMU
SDL grab with:

```text
Ctrl-Alt-G
```

## Display clarity

For XP desktop readability, use the standard VGA device with a higher guest
resolution and enable ClearType in Windows XP:

```text
Display Properties -> Appearance -> Effects -> Use the following method to smooth edges of screen fonts -> ClearType
```

Cirrus can work but has fewer usable resolution/color-depth combinations under
XP. qemu-3dfx 3D pass-through does not depend on increasing VGA VRAM beyond what
is needed for the guest desktop mode.

## Optional disk pacing

To make an SSD-backed qcow2 feel more like a period HDD, prefer a throughput
cap over a strict IOPS cap for the boot disk. A conservative example:

```xml
<iotune>
  <read_bytes_sec>5000000</read_bytes_sec>
  <write_bytes_sec>5000000</write_bytes_sec>
</iotune>
```

Very low IOPS caps can stall Windows XP boot or setup because XP performs many
small metadata operations.
