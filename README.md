# VPS 适用工具安装脚本

这是一个用于 **VPS/Linux 服务器初始化** 的工具安装脚本，支持一键安装常用的软件和系统工具，智能跳过已安装的包。

## 功能
- 🔹 安装常用编辑器和基础工具（nano、vim、git、wget、curl 等）
- 🔹 安装网络调试和监控工具（htop、iftop、mtr、tcpdump、netcat-openbsd 等）
- 🔹 安装并启用 `cron`
- 🔹 安装 Python3 环境
- 🔹 安装性能调优工具（ethtool、sysstat、lsof 等）
- 🔹 配置 `unattended-upgrades` 自动安全更新
- 🔹 自动清理无用包和缓存

## 一键执行
在 VPS 上执行以下命令即可一键运行（自动下载并执行最新脚本）：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/bgpeer/vps-net/main/setup-tools.sh)
```

---

## 🧬 BBRPlus 内核一键安装（慎用❗）

**📢适用于 RAM 足够的 KVM VPS**

**🚫⚠ 安装时确保自己机器可以重装或者里面没有重要资料再试，有些机器性能差或权限不够可能会死机！**

```bash
wget -O bbrplus.sh https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh && chmod +x bbrplus.sh && ./bbrplus.sh
```

---

## 🌏 vps-net-optimize

一键优化脚本，适用于 TCP / UDP / IPv6 / ulimit / MSS 等场景的 VPS 网络性能优化。

---

## 🚀 一键执行网络优化配置
❗**网络优化之前请先装VPS适用工具，否则网络优化可能安装不成功**

**👉复制以下命令，在 VPS 上粘贴执行：**

**自适应智能算法+抢占带宽模式（流量达到10m/s激活）适合内存小于1G机器的用户**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bgpeer/vps-net/main/net-optimize-ultimate.sh)
```
**自适应智能算法+抢占带宽模式（流量达到20m/s激活）适合内存2G左右机器的用户**（阀值可调）
```bash
ADAPTIVE_QOS_THRESHOLD=20971520 bash <(curl -fsSL https://raw.githubusercontent.com/bgpeer/vps-net/main/net-optimize-ultimate.sh)
```
**固定 cake 纯智能算法模式适合高性能机器用户**
```bash
ADAPTIVE_QOS_MODE=fixed_cake bash <(curl -fsSL https://raw.githubusercontent.com/bgpeer/vps-net/main/net-optimize-ultimate.sh)
```
---

## 🔍 一键检测当前网络优化状态

复制以下命令，在 VPS 上粘贴执行：

```bash
wget -qO- https://raw.githubusercontent.com/bgpeer/vps-net/main/net-optimize-check.sh | bash
```
---

## ❌ 一键还原并删除所有网络优化配置

复制以下命令，在 VPS 上粘贴执行：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bgpeer/vps-net/main/net-optimize-reset.sh)
```

---

# 🛰 VPS 11种协议一键安装脚本

由 mack-a 开发的 V2ray / Xray / Trojan / Reality 综合安装程序。

⚠️安装前请准备好**域名**托管到CF指向VPS的IP不要开小黄云才能执行代码

**步骤：
1️⃣ 选 1 安装 ， 2️⃣ 选 2 安装 Sing-box  ，3️⃣ 输入你自己的域名......，不懂就问AI**

```bash
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh" && chmod 700 /root/install.sh && /root/install.sh
```
代码跑完之后建议把所有的连接信息复制下来保存到**谷歌文档**，方便以后提取

**VL_WS / VM_WS / VM_HTTPUpgrade_TLS叠加smux**

```bash
python3 <(curl -sL https://raw.githubusercontent.com/bgpeer/vps-net/main/scripts/enable-multiplex.py)
```

**如果创建了屏蔽大陆域名，下面是放行白名单规则集脚本**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bgpeer/vps-net/main/whitelist-inject.sh)
```

---

# 📱 ClashMeta/Clash Mi可直接提取的 10 协议模板，只支持mihomo核心（移动端可用）

适用于 Android 手機 ClashMeta /Clash Mi（ Mihomo
）支持与 VPS 11协议配合使用：

[👉 一键查看模板](https://cdn.gh-proxy.org/https://gist.githubusercontent.com/bgpeer/099059cfce913ef7b80496fbf4241324/raw/us_la.yaml)

可以将此模板全部复制给gpt让他记住，然后把VPS的11个协议全部复制出来给gpt让他按照这个模板来提取连接配置更换就可以了

---

# 📱 Singbox 可直接提取的 10 协议模板

[👉 一键查看模板](https://cdn.gh-proxy.org/https://gist.github.com/bgpeer/ea81e07938efe1b2e892db7a9bee872e/raw/singbox-config.json)

---

**如果需要更多的分流配置规则请到旁边仓库观看**
https://github.com/bgpeer/rules

---

## ⚠️ 风险提示与免责声明

- 本仓库脚本会**修改系统内核参数、网络配置、软件源与内核**(如 BBR/BBRPlus、sysctl、ulimit 等),属于高风险操作。请在**可随时重装、无重要数据**的机器上使用;操作前务必**备份重要资料**。
- 脚本按「**现状(AS IS)**」提供,不作任何明示或暗示的担保。因使用本仓库脚本导致的系统异常、死机、数据丢失、服务中断或任何直接/间接损失,**由使用者自行承担**,作者不承担任何责任。
- 部分功能依赖或引用了**第三方脚本/项目**(例如 BBRPlus 内核安装来自 [ylx2016/Linux-NetSpeed](https://github.com/ylx2016/Linux-NetSpeed)),其版权与责任归各自作者所有,请遵循对应项目的许可协议。
- 请在遵守你所在地区**法律法规**及 VPS 服务商**服务条款**的前提下使用;网络代理/优化相关内容仅供学习与个人自用。

## 📄 License

本项目以 [MIT License](./LICENSE) 开源;第三方组件版权归其各自作者所有。
