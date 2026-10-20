# Real 2× HiDPI on an NVIDIA laptop GPU under macOS 26

**Getting 1760×990 @ 165 Hz out of a 2560×1440 internal panel on a GA106M (RTX 3060 Laptop) — root cause, patch, and measured limits.**

Status: working and in daily use. This documents what actually had to change, because the
usual advice ("just add a `scale-resolutions` override") is not enough on its own.

---

## TL;DR

On macOS 26 with the open-source NVIDIA kernel modules, any display mode whose *desktop size*
differs from the *mode raster* is rejected by NVKMS with per-head `INVALID_FLIP` (status 6) —
the mode appears in the list, you select it, and it silently bounces back. The reason is that
NVKMS skips parsing the layer (precomp) scaler capability table whenever a head (postcomp)
scaler exists, so the caps come back all-zero.

The fix is **not** to enable layer scaling. It is to keep the layer 1:1 and let the *head
viewport* do the scaling:

1. `NvKmsKapiMainLayerConfigToKms()` — program the main layer `sizeOut` with the **source**
   size instead of the destination size, so the flip is 1:1 at the desktop resolution.
2. `NvKmsKapiRequestedModeSetConfigToKms()` — set `paramsHead->viewPortSizeIn` to the
   **desktop** size instead of the mode raster timings.
3. Never request `allowHeadSurfaceInNvKms` on this path — it breaks commit validation.

Result on this machine: raster `3520×1980` downscaled to the `2560×1440` panel, giving a UI of
`1760×990` at 165 Hz with `kCGDisplayResolution = 2`.

---

## Environment

| Item | Value |
|---|---|
| Machine | Laptop, single dGPU driving the internal panel (no iGPU path) |
| GPU | NVIDIA RTX 3060 Laptop (GA106M), `0x10DE:0x2520`, 6 GB |
| Panel | BOE NE156QHM-NY1, 2560×1440, 165 Hz, 16:9, EDID `0x09E5:0x0A07` |
| OS | macOS 26.7.1 (build 25G241) |
| Bootloader | OpenCore (OCLP-style setup) |
| Driver | `nullmoth` NVIDIA kexts 2.4.3, built from `open-gpu-kernel-modules` 610.57.04 |
| SIP | `Kext Signing: disabled` (required for third-party kexts in the AuxKC) |
| Metal | Metal 3 |

The upstream patch this is based on ([issue #221](https://github.com/NVIDIA/open-gpu-kernel-modules))
was verified by its author on **GB203** only. This report adds a data point on **GA106M**
(Ampere mobile), which behaves the same way for downscaling.

---

## Symptom

On a fresh install the internal panel offers exactly two "clear" options:

- native `2560×1440` at 1× — everything is tiny on a 15.6" panel;
- `1280×720` at 2× — the only HiDPI mode macOS generates on its own, far too large.

Every intermediate size (`1600×900`, `1680×945`, `1720×967`, …) is either missing from the list
or, once injected via a display override, is rejected on selection: the screen flickers, the
resolution stays put, and nothing in the UI explains why.

`SwitchResX`-style tools do not help; this is a kernel-level validation failure, not a
userspace enumeration problem.

---

## Root cause, layer by layer

### 1. `nvfbhidpi=1` is wiped on every boot

The framebuffer kext only publishes scaled detailed timings when started with `nvfbhidpi=1`.
Appending it with `nvram boot-args=...` does not survive a reboot because OpenCore's
`NVRAM → Delete` list contains `boot-args`, so the variable is erased and rewritten from
`config.plist` before macOS starts.

The argument has to be added to `EFI/OC/config.plist`:

```
NVRAM → Add → 7C436110-AB2A-4BBB-A880-FE41995C9F82 → boot-args
  ... existing args ... nvfbhidpi=1
```

Without it, a `scale-resolutions` override produces nothing at all — which is easy to
misdiagnose as "the override doesn't work".

### 2. NVKMS refuses any scaled layer

`nvkms-kapi.c` builds the layer config, then the mode set is validated. When a display has a
head (postcomp) scaler, the precomp scaler capability table is never parsed, so
`nvAssignScalerTaps()` computes zero taps and the flip is rejected:

```
NVRM-fb: switchMode 0x80001003: test 3360x1890 -> raster 2560x1440 @165003 mHz
         pclk 704260000 -> 0 (flipResult 0)
```

`-> 0` is the failure. A mode whose desktop size equals the raster commits fine:

```
NVRM-fb: switchMode 0x80001000: test 2560x1440 -> raster 2560x1440 ... -> 1 (COMMIT)
```

This is exactly what issue #221 describes, and it is why every "middle" resolution bounces.

### 3. Override entries have two different meanings

`scale-resolutions` entries are 12 bytes: `width, height, flags=1` (big-endian). What the value
*means* depends on how it compares to the panel raster:

| Entry | Interpreted as | Effect |
|---|---|---|
| ≤ raster (e.g. `2560×1440`) | a **render buffer** | UI = entry / 2 → 1280×720 at 2× |
| > raster (e.g. `3520×1980`) | a **desktop size** | desktop 3520, downscaled by the head viewport |

Two consequences worth knowing:

- **Never write an entry equal to the raster.** It shadows the native 1:1 mode, so the largest
  "desktop" you can pick becomes 1280×720 — it looks like the machine is stuck.
- Entries larger than the raster only work *after* the patch below, because they require
  downscaling at the head.

---

## The patch

Three hunks against `src/nvidia-modeset/kapi/src/nvkms-kapi.c`. A runtime switch
`gNvkmsAllowHeadSurfaceOverride` is used to keep the stock path selectable
(`0` = stock, `1` = headSurface experiment, `2` = this approach; default `2`).

```c
/* runtime switch, default 2 */
int gNvkmsAllowHeadSurfaceOverride = 2;
```

**Hunk 1 — keep the layer at 1:1** (in `NvKmsKapiMainLayerConfigToKms()`):

```c
if (gNvkmsAllowHeadSurfaceOverride == 2 &&
    (layerConfig->srcWidth  != layerConfig->dstWidth ||
     layerConfig->srcHeight != layerConfig->dstHeight)) {
    params->layer[NVKMS_MAIN_LAYER].sizeOut.val.width  = layerConfig->srcWidth;
    params->layer[NVKMS_MAIN_LAYER].sizeOut.val.height = layerConfig->srcHeight;
}
```

**Hunk 2 — point the head viewport at the desktop** (in
`NvKmsKapiRequestedModeSetConfigToKms()`):

```c
if (gNvkmsAllowHeadSurfaceOverride) {
    const struct NvKmsKapiLayerRequestedConfig *lr0 =
        &headRequestedConfig->layerRequestedConfig[NVKMS_KAPI_LAYER_PRIMARY_IDX];
    const struct NvKmsKapiLayerConfig *lc0 = &lr0->config;

    if (lc0->surface != NULL &&
        (lc0->srcWidth  != lc0->dstWidth ||
         lc0->srcHeight != lc0->dstHeight)) {
        paramsHead->viewPortSizeIn.width  = lc0->srcWidth;
        paramsHead->viewPortSizeIn.height = lc0->srcHeight;
    }
}
```

**Hunk 3 — do not request `allowHeadSurfaceInNvKms`** except in the (broken) mode 1. This is
what makes the difference between a working mode and `INVALID_FLIP` at commit validation:

```c
if (gNvkmsAllowHeadSurfaceOverride == 1) {
    params->request.allowHeadSurfaceInNvKms = NV_TRUE;
}
```

Because hunk 1 also runs on later flips (not just modesets), a page flip cannot silently
reintroduce layer scaling — which is what caused the "it holds for one frame then snaps back"
behaviour in earlier attempts.

Full diff: [`patches/nvkms-kapi-planE.diff`](patches/nvkms-kapi-planE.diff).

### What did *not* work

| Attempt | Failure mode |
|---|---|
| Let the layer scale (`sizeOut` = dst) | `nvAssignScalerTaps()` sees a zeroed capability table → status 6 |
| `allowHeadSurfaceInNvKms = NV_TRUE` + scaled layer | commit=0 validation rejects it; kept behind mode `1` for reference |
| Only changing the mode-set path, not the flip path | mode commits, then the first flip reverts it |
| Override entry equal to the raster | shadows the native 1:1 mode |

---

## Measured ceiling

Override entries tried on this panel (all `flags=1`):

| Desktop entry | Committed | UI at 2× |
|---|---|---|
| 2880×1620 | yes | 1440×810 |
| 3200×1800 | yes | 1600×900 |
| 3360×1890 | yes | 1680×945 |
| 3440×1935 | yes (3440×1934) | 1720×967 |
| **3520×1980** | **yes** | **1760×990** ← in use |
| 3840×2160 | no — never enumerated | — |
| 4096×2304 | no — never enumerated | — |

The largest usable desktop is **3520 wide = 1.375 × the panel raster**. 3840 (1.5×) and 4096
(1.6×) disappear before reaching the mode list, so a 1920×1080 or 2048×1152 UI at 2× is not
reachable on this panel.

`fScalerMaxW` is `raster × 2 = 5120`, so a second, tighter constraint exists somewhere in mode
validation. It has not been isolated; the 1.375 ratio is suspiciously clean but might be a
coincidence of which entries survive enumeration.

165 Hz is preserved at every listed size, which requires the framebuffer kext to publish the
scaled detailed timings itself — macOS only generates scaled variants for its own EDID-derived
rates (≤60 Hz here).

---

## Verifying that you actually got HiDPI

Do **not** trust `CGDisplayModeGetWidth()`. With this driver it returns the pixel width, the
same as `CGDisplayModeGetPixelWidth()`, so a 1× mode and a 2× mode look identical to CoreGraphics.

The only reliable check is the system report:

```
Resolution: 3520 x 1980
UI Looks like: 1760 x 990 @ 165.00Hz
```

Ratio ≈ 2 → real HiDPI. The two numbers equal → 1× (blurry).

At the kernel level, a successful scaled mode logs `-> 1` / `COMMIT`, and a rejected one logs a
per-head status of 6.

---

## Reproducing it

1. **Boot argument.** Add `nvfbhidpi=1` to `boot-args` in OpenCore's `config.plist`
   (not via `nvram`), otherwise it is erased on every boot.
2. **Display override.** In
   `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vendor>/DisplayProductID-<product>`
   add `scale-resolutions` entries as 12-byte data (`width, height, 1`). Keep them **strictly
   greater** than the panel raster. `root:wheel`, mode `0644`.
3. **Build the patched NVRM.**

   ```bash
   # open-gpu-kernel-modules 610.57.04, nothing exotic:
   patch -p1 < patches/nvkms-kapi-planE.diff     # from the source root
   cd src/nvidia         && make -n -B TARGET_OS=Darwin TARGET_ARCH=x86_64 CC="..." > compile_cmds.sh
   cd src/nvidia-modeset && make -n -B TARGET_OS=Darwin TARGET_ARCH=x86_64 CC="..." >> compile_cmds.sh
   # compile all objects, then:
   libtool -static -o libnvkernel.a src/nvidia/_out/Darwin_x86_64/*.o
   libtool -static -o libnvkms.a    src/nvidia-modeset/_out/Darwin_x86_64/*.o
   # relink the kext against libnvkms.a + libnvkernel.a, ad-hoc sign
   ```

4. **Install into the AuxKC.**

   ```bash
   sudo ditto NVRM.kext /Library/Extensions/NVRM.kext
   sudo chown -R root:wheel /Library/Extensions/NVRM.kext     # <- see trap 1
   sudo kmutil create -n aux --volume-root / --allow-missing-kdk \
     --kernel /System/Library/Kernels/kernel \
     -B /System/Library/KernelCollections/BootKernelExtensions.kc \
     -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
     --repository /Library/Extensions -A /tmp/AuxKC.new -z
   # trap 2: verify before rebooting — without -A this reads the repository and lies
   sudo kmutil inspect -a x86_64 -A /tmp/AuxKC.new | grep -c com.nullmoth.NVRM
   sudo mv -f /tmp/AuxKC.new /Library/KernelCollections/AuxiliaryKernelExtensions.kc
   ```

5. **Persist the 2× choice.** A mode picked at runtime is not written back reliably; the
   WindowServer configuration lives in
   `~/Library/Preferences/ByHost/com.apple.windowserver.<UUID>.plist` and gets overwritten on
   shutdown. Writing it from a one-shot LaunchDaemon before WindowServer starts (then
   self-destructing) is the reliable route. Afterwards, choices made in System Settings stick.

---

## Two traps that cost the most time

1. **`ditto` preserves the source owner.** A kext not owned by `root:wheel` is *silently
   excluded* from the AuxKC. Nothing fails loudly; the driver simply does not load and the
   login window crash-loops. Always `chown -R root:wheel` after copying.
2. **`kmutil inspect` without `-A` reads the repository, not the collection.** It will happily
   report your kext as present while the actual `.kc` does not contain it. Verify the file you
   are about to install: `kmutil inspect -a x86_64 -A /tmp/AuxKC.new`.

A third, cheap one: `make -n` needs `TARGET_OS=Darwin TARGET_ARCH=x86_64` explicitly. Without
it the Makefile quietly emits Linux commands, and the resulting object files are useless.

---

## Risks and rollback

This is a patched kernel driver on an unsupported GPU. Assume a bad build can leave you without
a display.

- **The driver has no automatic rollback.** Its `bootguard` only records "this boot produced a
  desktop"; its `recover` service only uninstalls when a specific NVRAM variable is set. There
  is no "N failed boots → revert" logic. Keep a copy of the working kext and the working
  `AuxiliaryKernelExtensions.kc` on external media.
- Emergency uninstall: boot into Recovery, then
  `nvram 7C436110-AB2A-4BBB-A880-FE41995C9F82:nullmoth-remove=1` and reboot; the recovery
  service removes the driver and reboots.
- Or replace `/Library/KernelCollections/AuxiliaryKernelExtensions.kc` from a backup in Recovery.
- A system update rebuilds the AuxKC, so the patched kext must be reinstalled afterwards.

---

## Open questions

- What exactly caps the desktop at 1.375× the raster for downscaling? The cap table suggests
  2×, so something else (scaler taps? pixel clock? `validateDetailedTiming`?) is tighter.
- Upscaling at the head viewport (desktop < raster, e.g. 1600×900 on a 1920×1080 panel) passes
  the capability math but was not exercised here — this machine only has a 1440p panel.
- Multi-head: the loop covers all four heads, but only head 0 is populated in this setup.

---

## Credits

The runtime-switch approach and the `headSurface` dead end come from the analysis in
NVIDIA/open-gpu-kernel-modules issue #221. The macOS kext side builds on the `nullmoth`
NVIDIA driver for macOS.
