#!/usr/bin/env python3
"""并行编译 OGKM Darwin 对象，汇总失败项。"""
import concurrent.futures as cf
import os
import subprocess
import sys
import time

TREES = [("src/nvidia", "libnvkernel.a"), ("src/nvidia-modeset", "libnvkms.a")]
OGKM = os.path.expanduser("~/ogkm610")
LOG = os.path.expanduser("~/nvbuild/logs")
os.makedirs(LOG, exist_ok=True)
WORKERS = int(os.environ.get("WORKERS", "18"))

def run(tree):
    d = os.path.join(OGKM, tree)
    cmds = [l.rstrip("\n") for l in open(os.path.join(d, "_out/Darwin_x86_64/compile_cmds.sh")) if l.strip()]
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
            if done % 100 == 0:
                print(f"  {tree}: {done}/{len(cmds)}  失败 {len(fails)}  {time.time()-t0:.0f}s", flush=True)

    with open(os.path.join(LOG, f"{tag}-fails.log"), "w") as f:
        for i, err in fails:
            f.write(f"===== 失败 #{i}: {cmds[i][:200]}\n{err[-3000:]}\n\n")
    print(f"{tree}: 共 {len(cmds)} 个对象，失败 {len(fails)}，用时 {time.time()-t0:.0f}s")
    if fails:
        print(f"  失败明细: {LOG}/{tag}-fails.log")
        for i, err in fails[:5]:
            src = [t for t in cmds[i].split() if t.endswith((".c", ".cpp"))]
            print("   -", src[-1] if src else cmds[i][:80])
    return d, fails

for tree, _ in TREES:
    print(f"=== 编译 {tree} ===", flush=True)
    run(tree)
print("完成")
