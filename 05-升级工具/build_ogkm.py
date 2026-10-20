#!/usr/bin/env python3
"""并行编译 OGKM Darwin 对象，汇总失败项。

环境变量：
  OGKM     源码树根目录（必填，或默认 ~/ogkm610）
  WORKERS  并行线程数（默认 CPU 核数）
返回码：0 = 全部成功，1 = 有对象编译失败
"""
import concurrent.futures as cf
import os
import subprocess
import sys
import time

OGKM = os.environ.get("OGKM") or os.path.expanduser("~/ogkm610")
TREES = ["src/nvidia", "src/nvidia-modeset"]
LOG = os.environ.get("OGKM_LOGDIR") or os.path.join(OGKM, "_buildlogs")
os.makedirs(LOG, exist_ok=True)
WORKERS = int(os.environ.get("WORKERS") or os.cpu_count() or 8)


def run(tree):
    d = os.path.join(OGKM, tree)
    sh = os.path.join(d, "_out/Darwin_x86_64/compile_cmds.sh")
    if not os.path.isfile(sh):
        print(f"❌ 找不到编译命令表：{sh}")
        return tree, None
    cmds = [l.rstrip("\n") for l in open(sh) if l.strip()]
    tag = tree.replace("/", "-")
    fails = []
    t0 = time.time()
    done = 0

    def one(i_cmd):
        i, cmd = i_cmd
        p = subprocess.run(["bash", "-c", cmd], cwd=d, capture_output=True, text=True)
        return i, p.returncode, p.stderr

    with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for i, rc, err in ex.map(one, enumerate(cmds)):
            done += 1
            if rc != 0:
                fails.append((i, err))
            if done % 200 == 0:
                print(f"  {tree}: {done}/{len(cmds)}  失败 {len(fails)}  {time.time()-t0:.0f}s", flush=True)

    with open(os.path.join(LOG, f"{tag}-fails.log"), "w") as f:
        for i, err in fails:
            f.write(f"===== 失败 #{i}: {cmds[i][:300]}\n{err[-3000:]}\n\n")
    print(f"{tree}: 共 {len(cmds)} 个对象，失败 {len(fails)}，用时 {time.time()-t0:.0f}s")
    if fails:
        print(f"  失败明细: {LOG}/{tag}-fails.log")
        for i, _ in fails[:8]:
            src = [t for t in cmds[i].split() if t.endswith((".c", ".cpp", ".cxx"))]
            print("   -", src[-1] if src else cmds[i][:100])
    return tree, fails


all_ok = True
for tree in TREES:
    print(f"=== 编译 {tree} ===", flush=True)
    _, fails = run(tree)
    if fails is None or fails:
        all_ok = False

print("完成" if all_ok else "有失败，见上方明细")
sys.exit(0 if all_ok else 1)
