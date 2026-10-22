接入vpsx脚本  

## 实时日志

```bash
journalctl -u subconverter -f
```

# NAT-Subconverter-Nginx 一键交互式部署脚本

针对**小内存（≤512MB）、小硬盘（1~5GB）、无标准 Web 端口的 NAT VPS**，通过纯 Bash 脚本以交互式方式完成 Subconverter 后端及 Nginx 反代的极简部署与生命周期管理。

> 程序来源：[asdlokj1qpi233/subconverter](https://github.com/asdlokj1qpi233/subconverter)（支持 anytls / mieru / hy2 / hy / vless）
> 部署方式：二进制部署 + Systemd 守护 + Nginx 反代，**全程不依赖 Docker**

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
 0. 退出脚本
==================================================
```

- 首次运行自动进入**安装向导**；已安装则直接显示主菜单。
- 覆盖安装具备幂等性，整份配置重写，不会重复堆叠。

## 安装向导说明

| 步骤 | 说明 | 默认值 |
|---|---|---|
| 创建 Swap | 物理内存 ≤ 256MB 且无 Swap 时提示，防 OOM 崩溃 | Y（创建 512MB） |
| NAT 监听端口 | 填写 **NAT 服务商映射给您的内网端口**，禁止使用 25500 | 25580 |
| 绑定域名 | 仅通过 `IP:端口` 访问直接回车 | `_` |

安装内容：

1. 仅安装 `curl wget tar nginx`，完成后立即清理 apt 缓存防爆盘；
2. 按 CPU 架构下载 Subconverter 预编译包（3 次重试 + 完整性校验），解压至 `/opt/subconverter` 并立即删除安装包；
3. 写入 Systemd 服务（`Restart=always`，异常 5 秒自动拉起）；
4. 写入 Nginx 反代（关闭 access_log、error 级别 crit、请求体限制 10M），`nginx -t` 通过后启动；
5. 自动执行 `curl -I` 本地连通性验证。

## 使用示例

安装完成后，订阅转换请求格式：

```
http://<公网地址>:<公网端口>/sub?target=clash&url=<订阅链接>
```

对外访问请使用 **NAT 服务商映射的公网地址和公网端口**，脚本内端口填的是映射的内网端口。

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

## 完全卸载

主菜单选 `7`，自动完成：停止并禁用服务 → 删除 `/opt/subconverter` → 删除 Nginx 站点配置 → 移除脚本创建的 Swap，不留垃圾文件（nginx 软件包保留，如需删除执行 `apt-get purge nginx`）。

## 常见问题

- **下载 Subconverter 失败？** 编辑脚本顶部 `GH_PROXY=""`，填入加速前缀（如 `https://ghfast.top/`）后重试。
- **无法对外访问？** 确认 NAT 端口映射关系：脚本填内网端口，浏览器访问用公网端口；同时检查服务商防火墙。
- **内存太小怕崩？** 安装向导已提供 512MB Swap；查看内存占用用菜单 `2`。
- **安全提示：** 该转换接口默认**无鉴权**，请勿泄露访问地址；如需加固可在 Nginx 配置中自行添加 basic auth。

## 免责声明

本项目仅用于个人学习与技术研究，请遵守所在地区法律法规及服务商使用条款，勿用于非法用途。

## 许可证

本项目基于 [MIT License](LICENSE) 开源，可自由使用、修改与分发，请保留原始版权声明。
