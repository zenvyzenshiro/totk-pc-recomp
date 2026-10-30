# RDNA 2 / Zen 4 notes (branch feature/rdna2-zen4)

Target: Ryzen 5 7500F (6 cores, 12 threads), Radeon RX 6700 XT 12 GB, Adrenalin 26.10.1, TotK 1.4.3 at 2560x1440 and
60 fps. Nothing here has been run in game yet; every change keeps upstream behaviour unless a key turns it on.

## What changed

- `amd_preset` (runtime/cfg.c cfg_get): keys the environment and totk.ini leave unset take `vk_recorder = 0` and
  `astc = cpu`, the start configuration after `VK_ERROR_DEVICE_LOST` reports on RDNA 2. Which path causes the loss is
  not established; a key set on its own line wins, so each path can be tried again alone. Default 0.
- The Advanced tab (F1) shows `amd_preset` and `vk_recorder`, which existed only as an environment knob.
- The 3D render scale row adds 59 and 77 % and names AMD's FSR quality modes. The game's own final pass is FSR 1 EASU
  from the scene to the output (runtime/resolution.c), so the render scale is the FSR quality mode; no second
  resolution setting was added.
- tools/make_romfs_mod.py builds a checked overlay (TOTK_ROMFS_MODS) from a mod folder: RomFS version hash, original
  SHA-256, decompressed size of `.zs` files, conflicts with romfs-patches.

## Settings for this machine

Defaults already fit: `lib_prebuild_threads` (a quarter of the threads, 3), `prewarm_xlate` (half, 6), `memory = auto`
(mirror on a discrete GPU), `vk_present = mailbox`. The AMD driver keeps its pipeline cache per exe path: keep one build
folder, or rerun `totk.exe --warm-shaders` after preparing another.

## FSR 3.1 upscaling and frame generation: not implemented

The newest FSR the RX 6700 XT runs is FSR 3.1 (FSR 4 and the ML frame generation need RDNA 4). Both FSR 3.1 parts are
temporal and need, per frame, the scene colour before the game's upscale, depth, per-pixel motion vectors, the camera
jitter and the camera matrices. This renderer replays the game's NVN command stream; it does not know which render
target holds depth or velocity, the game renders no jittered frames for FSR 1, and frame generation also needs the UI
drawn into a separate surface and the swapchain handed to the FidelityFX frame interpolation swapchain. Identifying
those targets in TotK's renderer, adding jitter through a game patch and integrating the FidelityFX SDK Vulkan backend
(MIT) is the work left. Until then the menu has no FSR 3.1 or frame generation toggle: a toggle without that data
would do nothing or interpolate with wrong vectors.

FSR 1 remains: the game's own pass from the scene to the output, and runtime/vk_fsr.c from the output to the window.
