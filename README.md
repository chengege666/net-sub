接入vpsx脚本  

## 实时日志

```bash
journalctl -u subconverter -f
```

# NAT-Subconverter-Nginx 一键交互式部署脚本

针对**小内存（≤512MB）、小硬盘（1~5GB）、无标准 Web 端口的 NAT VPS**，通过纯 Bash 脚本以交互式方式完成 Subconverter 后端的极简部署与生命周期管理，支持 **Cloudflare Tunnel（HTTPS，推荐）** 与 **Nginx 反代（HTTP）** 两种对外接入方式。

> 程序来源：[asdlokj1qpi233/subconverter](https://github.com/asdlokj1qpi233/subconverter)（支持 anytls / mieru / hy2 / hy / vless）
> 部署方式：二进制部署 + Systemd 守护 + Cloudflare Tunnel / Nginx 反代，**全程不依赖 Docker**

---

## 一键安装

SSH 连上 VPS 后执行（回车两次即可用默认参数完成安装）：

```bash
wget -qO sub_mgr.sh https://raw.githubusercontent.com/chengege666/net-sub/main/sub_mgr.sh && sudo bash sub_mgr.sh
```

国内机器下载 GitHub 困难时，使用加速前缀（镜像站失效请自行更换）：

```bash
wget -qO sub_mgr.sh https://ghfast.top/https://raw.githubusercontent.com/chengege666/net-sub/main/sub_mgr.sh && sudo bash sub_mgr.sh
```

> 说明：仓库地址为 `https://github.com/chengege666/net-sub`；若默认分支是 `master` 请将 `main` 一并替换。

---

## 环境要求

| 维度 | 要求 |
|---|---|
| 操作系统 | Debian 10/11/12、Ubuntu 20.04/22.04/24.04（apt + systemd） |
| 硬件底线 | 内存 ≥ 128MB，磁盘剩余 ≥ 150MB |
| CPU 架构 | x86_64 (amd64) 与 aarch64 (arm64) 自动识别 |
| 网络环境 | NAT IPv4（无公网 80/443，仅映射内网指定端口至公网） |

资源占用：安装后新增磁盘 ≤ 60MB；空闲内存 Subconverter ≤ 30MB + Nginx ≤ 10MB。

---

## 功能菜单

```
==================================================
        NAT VPS Subconverter 极简管理脚本
==================================================
 1. 全新安装 / 覆盖安装
 2. 查看服务运行状态与内存占用
 3. 启动所有服务 (Subconverter + Nginx)
 4. 停止所有服务
 5. 重启所有服务
 6. 修改配置 (NAT监听端口 / 绑定域名)
 7. 一键完全卸载 (清理所有文件与配置)
 8. 更新 Subconverter 程序
 9. 配置 Cloudflare Tunnel (HTTPS 加密访问)
 0. 退出脚本
==================================================
```

- 首次运行自动进入**安装向导**；已安装则直接显示主菜单。
- 覆盖安装具备幂等性，整份配置重写，不会重复堆叠。
- 选项 `9` 见下方 [Cloudflare Tunnel HTTPS 接入](#cloudflare-tunnel-https-接入) 章节。

## 安装向导说明

安装向导第一步选择**对外接入方式**：

| 模式 | 说明 | 特点 |
|---|---|---|
| 1. Cloudflare Tunnel（默认，推荐） | 只装 Subconverter 本体，随后用菜单 `9` 接入隧道 | HTTPS 加密；纯出站连接，**不占用本机任何监听端口**，不影响节点等已有服务 |
| 2. Nginx 反代（传统） | 装 Nginx 并反代到后端 | HTTP 明文；需要 NAT 映射端口 |

> ⚠️ **Nginx 模式端口警示**：Nginx 会实际绑定所填的内网监听端口。如果误填了节点等其他服务正在使用的端口（如 NAT 映射给节点隧道的内网端口），会导致对应服务离线。请只填写确认空闲的端口，禁止使用 25500（Subconverter 内部端口）。

Nginx 模式的交互步骤：

| 步骤 | 说明 | 默认值 |
|---|---|---|
| 创建 Swap | 物理内存 ≤ 256MB 且无 Swap 时提示，防 OOM 崩溃 | Y（创建 512MB） |
| NAT 监听端口 | 填写 **确认空闲的内网端口**，禁止使用 25500 | 25580 |
| 绑定域名 | 仅通过 `IP:端口` 访问直接回车 | `_` |

安装内容：

1. 核心依赖仅装 `curl wget tar`（Nginx 模式额外装 nginx），完成后立即清理 apt 缓存防爆盘；
2. 按 CPU 架构下载 Subconverter 预编译包（3 次重试 + 完整性校验），解压至 `/opt/subconverter` 并立即删除安装包；
3. 写入 Systemd 服务（`Restart=always`，异常 5 秒自动拉起）；
4. Nginx 模式写入反代配置（关闭 access_log、error 级别 crit、请求体限制 10M），`nginx -t` 通过后启动；
5. 自动访问 `127.0.0.1:25500/version` 做本地连通性验证（两种模式通用）。

## 使用示例

**Tunnel 模式**（推荐，配好菜单 `9` 后）：

```
https://<您的域名>/sub?target=clash&url=<订阅链接>
```

**Nginx 模式**：

```
http://<公网地址>:<公网端口>/sub?target=clash&url=<订阅链接>
```

对外访问请使用 **NAT 服务商映射的公网地址和公网端口**，脚本内端口填的是映射的内网端口。

---

## Cloudflare Tunnel HTTPS 接入

主菜单选 `9`，脚本自动完成 cloudflared 安装、隧道创建、DNS 绑定与服务注册，让订阅地址从 `http://` 升级为 `https://`，**无需公网标准端口**（NAT 高位端口也能用）。

### 前提条件

1. 拥有一个域名，且已托管到 Cloudflare（免费版即可）；
2. VPS 能正常访问外网（Tunnel 走出站连接，不需要任何入站端口映射）。

### 向导流程

| 步骤 | 脚本动作 | 需要您做的 |
|---|---|---|
| 输入域名 | 校验主机名格式 | 填完整子域名，如 `jp.example.com` |
| 安装客户端 | 按架构下载 cloudflared 至 `/usr/local/bin` | 无 |
| 账号登录 | 执行 `cloudflared tunnel login` | 浏览器打开授权 URL，选择域名的 Zone |
| 创建隧道 | 创建/复用名为 `net-sub` 的隧道 | 无 |
| 写入配置 | 生成 `/etc/cloudflared/config.yml`，流量转发至 `localhost:25500` | 无 |
| 绑定 DNS | 执行 `cloudflared tunnel route dns` | 若该主机名已有旧 A 记录，需先到 Cloudflare 控制台删除 |
| 注册服务 | `cloudflared service install` 并启动，开机自启 | 无 |
| 验证 | 自动请求 `https://<域名>/version` | 无 |

登录环节注意：`cloudflared tunnel login` 在 SSH 里会打印一个授权 URL。若授权后浏览器跳转的 `localhost` 回调页打不开，复制浏览器地址栏完整的回调地址，另开一个 SSH 终端执行 `curl -s '<回调地址>'` 即可完成登录。

### 使用效果

- 订阅地址：`https://<您的域名>/sub?target=clash&url=<订阅链接>`
- Tunnel 直连 Subconverter 内部端口 25500，不经过 Nginx；配置时若检测到旧 Nginx 站点配置，会**自动停用并删除**，释放其占用的端口（避免抢占节点端口导致离线）
- 菜单 `2` 状态页会显示 Tunnel 运行状态

### 常见问题

- **route dns 失败？** 多为该主机名已存在旧 A 记录冲突，到 Cloudflare 控制台 DNS 页面删除后重跑选项 `9`（幂等，可安全重复执行）。
- **验证未通过？** DNS 生效与隧道建立有延迟，稍候重试；排查 `journalctl -u cloudflared -n 30`。
- **云端残留：** 卸载脚本只清理 VPS 本地配置，云端隧道与 DNS 记录需自行到 Cloudflare 控制台删除。

## 常用运维命令

```bash
sudo bash sub_mgr.sh              # 打开管理菜单（推荐）
systemctl status subconverter     # 查看后端服务状态
journalctl -u subconverter -n 20  # 查看后端最近 20 行日志
systemctl status nginx            # 查看 Nginx 状态
nginx -t                          # Nginx 配置语法检查
```

## 文件位置

| 路径 | 说明 |
|---|---|
| `/opt/subconverter/` | Subconverter 程序目录 |
| `/etc/systemd/system/subconverter.service` | Systemd 服务单元 |
| `/etc/nginx/conf.d/subconverter.conf` | Nginx 站点配置（端口/域名在此） |
| `/var/log/nginx/sub_error.log` | Nginx 错误日志（仅记录 crit 级别） |
| `/swapfile` | 脚本创建的虚拟内存（卸载时自动移除） |
| `/usr/local/bin/cloudflared` | Tunnel 客户端程序（仅使用选项 9 时存在） |
| `/etc/cloudflared/config.yml` | Tunnel 转发配置（卸载时自动移除） |
| `/root/.cloudflared/` | Cloudflare 登录凭据与隧道密钥（卸载时保留，需自行删除） |

## 完全卸载

主菜单选 `7`，自动完成：停止并禁用服务 → 删除 `/opt/subconverter` → 删除 Nginx 站点配置 → 移除脚本创建的 Swap → 清理 Tunnel 本地配置与系统服务（云端隧道需自行到 Cloudflare 控制台删除），不留垃圾文件（nginx 软件包保留，如需删除执行 `apt-get purge nginx`）。

## 常见问题

- **下载 Subconverter 失败？** 编辑脚本顶部 `GH_PROXY=""`，填入加速前缀（如 `https://ghfast.top/`）后重试。
- **无法对外访问？** 确认 NAT 端口映射关系：脚本填内网端口，浏览器访问用公网端口；同时检查服务商防火墙。
- **内存太小怕崩？** 安装向导已提供 512MB Swap；查看内存占用用菜单 `2`。
- **安全提示：** 该转换接口默认**无鉴权**，请勿泄露访问地址；如需加固可在 Nginx 配置中自行添加 basic auth。

## 免责声明

本项目仅用于个人学习与技术研究，请遵守所在地区法律法规及服务商使用条款，勿用于非法用途。

## 许可证

本项目基于 [MIT License](LICENSE) 开源，可自由使用、修改与分发，请保留原始版权声明。
