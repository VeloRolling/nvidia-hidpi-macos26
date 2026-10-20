# macOS 26 下 NVIDIA 笔记本独显实现真 2× HiDPI

**在 2560×1440 @165Hz 内屏上，用 GA106M（RTX 3060 Laptop）拿到 1760×990 @165Hz —— 根因、补丁与实测上限。**

状态：已跑通并日常使用。这里记录的是「真正必须改的东西」，因为网上常见的
「加一条 `scale-resolutions` override 就好了」在这一代驱动上并不成立。

---

## 太长不看

macOS 26 + 开源 NVIDIA 内核模块的组合下，任何「桌面尺寸 ≠ 模式 raster」的显示模式都会被
NVKMS 以 per-head `INVALID_FLIP`（status 6）拒绝：模式能出现在列表里，选中后屏幕闪一下又弹回，
界面上没有任何提示。

原因是：只要该显示器存在 head（后级 postcomp）缩放器，NVKMS 就会跳过解析图层（前级 precomp）
缩放器的能力表，能力值全为零，`nvAssignScalerTaps()` 自然算不出抽头。

**正确解法不是让图层去缩放**，而是让图层保持 1:1、把缩放交给 head viewport：

1. `NvKmsKapiMainLayerConfigToKms()` —— 主图层 `sizeOut` 用**源尺寸**而不是目标尺寸，
   使翻转在桌面分辨率上 1:1；
2. `NvKmsKapiRequestedModeSetConfigToKms()` —— `paramsHead->viewPortSizeIn` 设为**桌面尺寸**
   而不是模式 raster；
3. 这条路径上**不要**请求 `allowHeadSurfaceInNvKms`，否则提交校验会失败。

本机结果：raster `3520×1980` 下采样到 `2560×1440` 面板，界面 `1760×990`，165Hz，
`kCGDisplayResolution = 2`。

---

## 环境

| 项目 | 值 |
|---|---|
| 机型 | 笔记本，单 dGPU 直连内屏（无核显通路） |
| GPU | NVIDIA RTX 3060 Laptop（GA106M），`0x10DE:0x2520`，6GB |
| 面板 | BOE NE156QHM-NY1，2560×1440，165Hz，16:9，EDID `0x09E5:0x0A07` |
| 系统 | macOS 26.7.1（25G241） |
| 引导 | OpenCore |
| 驱动 | `nullmoth` NVIDIA kexts 2.4.3，源码 `open-gpu-kernel-modules` 610.57.04 |
| SIP | `Kext Signing: disabled`（第三方 kext 进 AuxKC 的前提） |

上游 issue #221 的作者只在 **GB203** 上验证过。本文补充了 **GA106M**（Ampere 移动）的数据点：
对下采样方向行为一致。

---

## 症状

内屏只有两个「清晰」选项：原生 `2560×1440` 的 1×（15.6 寸上字太小），以及
`1280×720` 的 2×（macOS 自己生成的那一档，字太大）。

中间的 `1600×900` / `1680×945` / `1720×967` 要么列表里没有，要么通过 override 注入后
一选就弹回。SwitchResX 之类的工具没用——这是内核层校验失败，不是用户层枚举问题。

---

## 三层根因

### 1. 每次开机 `nvfbhidpi=1` 都被抹掉

帧缓冲 kext 只有在带 `nvfbhidpi=1` 启动时才会放出缩放 detailed timing。用
`nvram boot-args=...` 追加无效：OpenCore 的 `NVRAM → Delete` 里有 `boot-args`，
开机先删再用 `config.plist` 里的值写回。

必须改 `EFI/OC/config.plist`：

```
NVRAM → Add → 7C436110-AB2A-4BBB-A880-FE41995C9F82 → boot-args
  ... 原有参数 ... nvfbhidpi=1
```

少了它，override 一条效果都没有，很容易误判成「override 不生效」。

### 2. NVKMS 拒绝任何缩放图层

```
NVRM-fb: switchMode 0x80001003: test 3360x1890 -> raster 2560x1440 ... -> 0 (flipResult 0)
```

`-> 0` 就是失败；桌面等于 raster 时才 `COMMIT ... -> 1`。这就是 issue #221 描述的现象，
也是所有「中间档」弹回的直接原因。

### 3. override 条目有两种语义

`scale-resolutions` 每条 12 字节：`宽, 高, flags=1`（大端）。值代表什么，取决于和 raster 的大小关系：

| 条目 | 解释 | 效果 |
|---|---|---|
| ≤ raster（如 `2560×1440`） | **渲染缓冲** | 界面 = 条目 / 2 → 1280×720 @2× |
| > raster（如 `3520×1980`） | **桌面尺寸** | 桌面 3520，由 head viewport 下采样 |

两个必须记住的推论：

- **绝对不要写等于 raster 的那一条**。它会顶掉原生 1:1 档，于是你能选的最大桌面变成
  1280×720，看起来就像「换不回去了」。
- 大于 raster 的条目，只有在打完下面的补丁之后才有意义（它需要 head 做下采样）。

---

## 补丁

针对 `src/nvidia-modeset/kapi/src/nvkms-kapi.c` 的三处改动。用一个运行时开关
`gNvkmsAllowHeadSurfaceOverride` 保留原路径可切换（`0` 原始、`1` headSurface 实验、
`2` 本方案，默认 `2`）。

**改动 1 —— 图层保持 1:1**（`NvKmsKapiMainLayerConfigToKms()`）

```c
if (gNvkmsAllowHeadSurfaceOverride == 2 &&
    (layerConfig->srcWidth  != layerConfig->dstWidth ||
     layerConfig->srcHeight != layerConfig->dstHeight)) {
    params->layer[NVKMS_MAIN_LAYER].sizeOut.val.width  = layerConfig->srcWidth;
    params->layer[NVKMS_MAIN_LAYER].sizeOut.val.height = layerConfig->srcHeight;
}
```

**改动 2 —— head viewport 指向桌面尺寸**（`NvKmsKapiRequestedModeSetConfigToKms()`）

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

**改动 3 —— 不要请求 headSurface**（只有已废弃的 mode 1 才置真）

```c
if (gNvkmsAllowHeadSurfaceOverride == 1) {
    params->request.allowHeadSurfaceInNvKms = NV_TRUE;
}
```

改动 1 同时作用于后续的每一次翻转（不只是 modeset），所以翻转不会悄悄把图层缩放又加回来——
这正是早期版本「撑住一帧就弹回」的原因。

完整 diff：[`patches/nvkms-kapi-planE.diff`](patches/nvkms-kapi-planE.diff)

### 试过但走不通的

| 做法 | 失败方式 |
|---|---|
| 让图层缩放（`sizeOut` = 目标尺寸） | 能力表全零 → status 6 |
| `allowHeadSurfaceInNvKms` = 真 + 缩放图层 | commit=0 校验拒绝（保留在 mode 1 作参考） |
| 只改 modeset 路径、不改翻转路径 | 模式提交成功，第一次翻转就回退 |
| 写一条等于 raster 的 override | 顶掉原生 1:1 档 |

---

## 实测上限

本面板上试过的 override 条目（均 `flags=1`）：

| 桌面条目 | 是否提交 | 2× 后界面 |
|---|---|---|
| 2880×1620 | 是 | 1440×810 |
| 3200×1800 | 是 | 1600×900 |
| 3360×1890 | 是 | 1680×945 |
| 3440×1935 | 是（实际 3440×1934） | 1720×967 |
| **3520×1980** | **是** | **1760×990** ← 当前使用 |
| 3840×2160 | 否，未出现在列表 | — |
| 4096×2304 | 否，未出现在列表 | — |

最大可用桌面宽 **3520 = raster 的 1.375 倍**。3840（1.5×）和 4096（1.6×）在模式枚举阶段就消失了，
所以本机拿不到 1920×1080 / 2048×1152 的 2× 缓冲。

`fScalerMaxW` 是 `raster × 2 = 5120`，说明模式校验里还有一条更紧的约束没被定位。1.375 这个比例
干净得可疑，也可能只是「哪些条目恰好能活过枚举」的巧合。

每个尺寸都保住了 165Hz —— 这要求帧缓冲 kext 自己发布缩放后的 detailed timing，
因为 macOS 只会为它自己从 EDID 推出来的刷新率（这里 ≤60Hz）生成缩放档。

---

## 怎么确认你真的拿到了 HiDPI

**不要信 `CGDisplayModeGetWidth()`。** 在这套驱动下它返回像素宽度，和
`CGDisplayModeGetPixelWidth()` 一样，1× 和 2× 在 CoreGraphics 眼里长得一模一样。

唯一可靠的判据是系统报告：

```
Resolution: 3520 x 1980
UI Looks like: 1760 x 990 @ 165.00Hz
```

比值约等于 2 → 真 HiDPI；两数相等 → 1×，一定发虚。

内核层：成功的缩放模式会打 `-> 1` / `COMMIT`，被拒的会打 per-head status 6。

---

## 复现步骤

1. **启动参数**：在 OpenCore `config.plist` 的 `boot-args` 末尾加 `nvfbhidpi=1`（别用 `nvram`）。
2. **显示 override**：在
   `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vendor>/DisplayProductID-<product>`
   里加 `scale-resolutions`，每条 12 字节（宽、高、1），且**必须严格大于**面板 raster。
   权限 `root:wheel` `0644`。
3. **编译打过补丁的 NVRM**：在源码根目录 `patch -p1 < patches/nvkms-kapi-planE.diff`，
   用 `make -n -B TARGET_OS=Darwin TARGET_ARCH=x86_64` 生成编译命令，并行编译，
   再用 `libtool -static` 归成 `libnvkernel.a` / `libnvkms.a`，与 kext 侧源码一起重链接、ad-hoc 签名。
4. **装进 AuxKC**：

   ```bash
   sudo ditto NVRM.kext /Library/Extensions/NVRM.kext
   sudo chown -R root:wheel /Library/Extensions/NVRM.kext     # 坑 1
   sudo kmutil create -n aux --volume-root / --allow-missing-kdk \
     --kernel /System/Library/Kernels/kernel \
     -B /System/Library/KernelCollections/BootKernelExtensions.kc \
     -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
     --repository /Library/Extensions -A /tmp/AuxKC.new -z
   # 坑 2：重启前必须验，不带 -A 读的是仓库，会给假 OK
   sudo kmutil inspect -a x86_64 -A /tmp/AuxKC.new | grep -c com.nullmoth.NVRM
   sudo mv -f /tmp/AuxKC.new /Library/KernelCollections/AuxiliaryKernelExtensions.kc
   ```

5. **把 2× 选择存下来**：运行时切换的模式不一定写回，
   `~/Library/Preferences/ByHost/com.apple.windowserver.<UUID>.plist` 会在关机时被覆盖。
   可靠做法是用一次性 LaunchDaemon 在 WindowServer 启动前写入再自毁；之后在系统设置里选的档位就能正常保存。

---

## 最费时间的两个坑

1. **`ditto` 会保留源文件的属主。** 不是 `root:wheel` 的 kext 会被 AuxKC **静默排除**：
   没有报错，驱动就是加载不上，登录窗口反复崩。拷完必须 `chown -R root:wheel`。
2. **`kmutil inspect` 不带 `-A` 读的是仓库而不是集合。** 它会告诉你 kext 在，
   而真正要装的那个 `.kc` 里其实没有。一定验文件：`kmutil inspect -a x86_64 -A /tmp/AuxKC.new`。

顺带一个便宜的：`make -n` 必须显式给 `TARGET_OS=Darwin TARGET_ARCH=x86_64`，
否则 Makefile 默默生成 Linux 的编译命令，编出来的对象文件没用。

---

## 风险与回滚

这是在不被支持的 GPU 上跑改过的内核驱动。假定一次错误的构建会让你没有画面。

- **驱动没有自动回滚。** 它的 `bootguard` 只记录「这次启动出了桌面」，`recover` 服务只在
  特定 NVRAM 变量存在时才卸载。**没有「失败 N 次就还原」的逻辑。** 工作版本的 kext 和
  `AuxiliaryKernelExtensions.kc` 必须另存到外部介质。
- 急救卸载：进恢复模式，`nvram 7C436110-AB2A-4BBB-A880-FE41995C9F82:nullmoth-remove=1`，
  重启后恢复服务会卸掉驱动并自动重启。
- 或者在恢复模式里用备份覆盖 `/Library/KernelCollections/AuxiliaryKernelExtensions.kc`。
- 系统更新会重建 AuxKC，补丁版 kext 必须重装。

---

## 未解决的问题

- 下采样到底卡在 1.375× 的哪一条？能力表说可以到 2×，说明还有更紧的约束没找到。
- 上采样方向（桌面 < raster）只过了能力计算，没在真机上跑过（本机只有 1440p 面板）。
- 多显示器：代码循环覆盖 4 个 head，但本机只有 head 0 有实际输出。

---

## 致谢

运行时开关的思路与 `headSurface` 这条死路来自 NVIDIA/open-gpu-kernel-modules issue #221 的分析；
macOS 侧的 kext 建立在 `nullmoth` 的 NVIDIA 驱动之上。
