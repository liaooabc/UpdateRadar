#!/usr/bin/env python3
"""
生成 Resources/cask-map.json —— 那张「App 名 / bundle id → Homebrew Cask 名」的表。

为什么要有这张表：
  运行时只按需拉单个 cask 的 JSON（约 1KB），不下载 18MB 的完整索引。
  但要知道「Keka.app 对应 keka 这个 cask」，就得先有一张映射表，随 App 一起发布。

什么时候重新生成：
  - 想覆盖更多 App（社区新上架的 cask）时，每隔一两个月跑一次
  - 用法：python3 tools/make_cask_map.py

数据来源：https://formulae.brew.sh/api/cask.json（Homebrew 官方 API）
"""
import json
import os
import re
import urllib.request

URL = "https://formulae.brew.sh/api/cask.json"
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "cask-map.json")

# 手工补的：pkg 安装（没有 .app 产物）或 .app 名字和 cask 里对不上的
MANUAL = {
    "com.microsoft.Word": "microsoft-word",
    "com.microsoft.Excel": "microsoft-excel",
    "com.microsoft.Powerpoint": "microsoft-powerpoint",
    "com.microsoft.Outlook": "microsoft-outlook",
    "com.microsoft.onenote.mac": "microsoft-onenote",
    "com.topazlabs.Topaz-Video": "topaz-video-ai",
    "com.topazlabs.TopazGigapixel": "topaz-gigapixel-ai",
    "com.topazlabs.TopazPhoto": "topaz-photo-ai",
    "com.canva.CanvaDesktop": "canva",
}


def apps_of(cask):
    out = []
    for a in cask.get("artifacts", []):
        if isinstance(a, dict) and "app" in a:
            v = a["app"]
            for x in v if isinstance(v, list) else [v]:
                if isinstance(x, str):
                    out.append(x)
    return out


def bundles_of(cask):
    ids = set()
    for a in cask.get("artifacts", []):
        if isinstance(a, dict) and "uninstall" in a:
            for part in re.findall(r"[A-Za-z0-9][\w.-]*", json.dumps(a["uninstall"])):
                if part.count(".") >= 2 and not part.endswith((".app", ".pkg", ".dmg", ".plist")):
                    ids.add(part)
    return ids


def main():
    print("▸ 下载 Homebrew Cask 索引（约 2MB 压缩传输）…")
    req = urllib.request.Request(URL, headers={"Accept-Encoding": "gzip",
                                              "User-Agent": "UpdateRadar/1.x"})
    with urllib.request.urlopen(req, timeout=600) as r:
        raw = r.read()
        if r.headers.get("Content-Encoding") == "gzip":
            import gzip
            raw = gzip.decompress(raw)
    casks = json.loads(raw)
    print(f"  cask 总数 {len(casks)}")

    apps, bundles = {}, {}
    for c in casks:
        ver = (c.get("version") or "").split(",")[0]
        if not ver or ver == "latest" or not ver[0].isdigit():
            continue
        for a in apps_of(c):
            apps.setdefault(a.lower(), c["token"])
        for b in bundles_of(c):
            bundles.setdefault(b, c["token"])
    bundles.update(MANUAL)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"apps": apps, "bundles": bundles}, f, ensure_ascii=False, separators=(",", ":"))
    print(f"▸ 写出 {os.path.normpath(OUT)}")
    print(f"  app 名 {len(apps)} 条 | bundle id {len(bundles)} 条 | {os.path.getsize(OUT)//1024} KB")


if __name__ == "__main__":
    main()
