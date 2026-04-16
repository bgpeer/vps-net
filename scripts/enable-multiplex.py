#!/usr/bin/env python3
"""
enable-multiplex.py
为 mack-a v2ray-agent sing-box 配置启用 multiplex（多路复用）

用法:
  python3 <(curl -sL https://raw.githubusercontent.com/bgpeer/vps-net/main/scripts/enable-multiplex.py)
  # 或
  python3 enable-multiplex.py [config路径]
"""

import json, shutil, subprocess, sys, time
from datetime import datetime

CONFIG = sys.argv[1] if len(sys.argv) > 1 else \
         "/etc/v2ray-agent/sing-box/conf/config.json"

if not __import__("os").path.isfile(CONFIG):
    print(f"❌ 配置文件不存在: {CONFIG}")
    print("用法: python3 enable-multiplex.py [config路径]")
    sys.exit(1)

BAK = f"{CONFIG}.bak.{datetime.now().strftime('%Y%m%d_%H%M%S')}"

# 支持 multiplex 的协议
SUPPORT_MUX  = {"vless", "vmess", "trojan", "shadowsocks"}
# 自带多路复用、无需加的 transport
NO_TRANSPORT = {"grpc"}

MUX_CFG = {"enabled": True, "padding": True}

with open(CONFIG) as f:
    cfg = json.load(f)

shutil.copy2(CONFIG, BAK)
print(f"✅ 已备份 → {BAK}")

added, skipped = [], []

for ib in cfg.get("inbounds", []):
    t   = ib.get("type", "")
    tag = ib.get("tag") or t
    tr  = ib.get("transport", {}).get("type", "")

    if t not in SUPPORT_MUX:
        skipped.append(f"{tag}（{t} 不支持）")
        continue
    if tr in NO_TRANSPORT:
        skipped.append(f"{tag}（gRPC 自带多路复用）")
        continue
    if any(u.get("flow") == "xtls-rprx-vision" for u in ib.get("users", [])):
        skipped.append(f"{tag}（Vision flow 不兼容）")
        continue
    existing = ib.get("multiplex", {})
    if existing.get("enabled") is True:
        skipped.append(f"{tag}（已启用，跳过）")
        continue
    # enabled=false 或不存在时，覆盖写入
    action = "覆盖（原为 disabled）" if "multiplex" in ib else "新增"
    ib["multiplex"] = MUX_CFG
    added.append(f"{tag}（{t}+{tr or 'tcp'}，{action}）")

print(f"\n➕ 添加 multiplex（{len(added)} 个）：")
for s in added:
    print(f"   {s}")
print(f"\n⏭  跳过（{len(skipped)} 个）：")
for s in skipped:
    print(f"   {s}")

if not added:
    print("\n无变更，退出。")
    sys.exit(0)

with open(CONFIG, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print("\n✅ 配置已写入")

subprocess.run(["systemctl", "restart", "sing-box"], check=True)
print("✅ sing-box 已重启，等待 2s...")
time.sleep(2)

r = subprocess.run(["systemctl", "is-active", "sing-box"],
                   capture_output=True, text=True)
if r.stdout.strip() == "active":
    print("✅ sing-box 运行正常")
else:
    print("❌ 启动失败，查日志：journalctl -u sing-box -n 50")
    sys.exit(1)
