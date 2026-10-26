#!/usr/bin/env bash
#=============================================================================
# NAT VPS 订阅转换极简管理脚本 (sub_mgr.sh)
#-----------------------------------------------------------------------------
# 适用系统 : Debian 10/11/12, Ubuntu 20.04/22.04/24.04 (仅限 apt + systemd)
# 运行环境 : NAT VPS (小内存 / 小硬盘 / 无标准 Web 端口), x86_64 或 aarch64
# 可选后端 : subconverter (C++, 协议覆盖全)  /  sub-api (Go, 单文件 <6MB, 空闲 <10MB)
# 部署方式 : 二进制部署 + Systemd 守护 + Nginx 反代 (严禁 Docker)
# 使用方法 : sudo bash sub_mgr.sh
# 注意事项 : 上传到 VPS 时请保持 LF 换行符 (必要时执行 dos2unix sub_mgr.sh)
#=============================================================================

#--------------------------- 全局配置 ---------------------------#
GH_PROXY=""                                                 # GitHub 加速前缀(可选), 例: https://ghproxy.com/
INSTALL_DIR="/opt/subconverter"                             # 程序安装目录 (两个后端共用)
SERVICE_NAME="subconverter"                                 # Systemd 服务名 (两个后端共用)
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"  # Systemd 单元文件路径
NGINX_CONF="/etc/nginx/conf.d/subconverter.conf"            # Nginx 站点配置文件路径
BACKEND_STATE="/etc/sub-mgr.backend"                        # 后端状态文件 (菜单操作自动感知已装后端)
DEFAULT_INTERNAL_PORT="25500"                               # 后端内部监听端口 (两个后端统一对齐)
DEFAULT_NAT_PORT="25580"                                    # Nginx 默认 NAT 监听端口
SWAP_FILE="/swapfile"                                       # 虚拟内存文件路径
SWAP_SIZE_MB="512"                                          # 虚拟内存大小 (MB)
SWAP_FSTAB_TAG="nat-sub-mgr"                                # fstab 标记 (用于卸载时识别脚本创建的 Swap)

# --- subconverter 后端 profile ---
REPO_SUBCONVERTER="asdlokj1qpi233/subconverter"
ASSET_FMT_SUBCONVERTER="tar.gz"
BIN_NAME_SUBCONVERTER="subconverter"
VERIFY_PATH_SUBCONVERTER="/version"
ASSET_AMD64_SUBCONVERTER="subconverter_linux64.tar.gz"
ASSET_ARM64_SUBCONVERTER="subconverter_aarch64.tar.gz"

# --- sub-api 后端 profile ---
REPO_SUBAPI="chengege666/sub-api"
ASSET_FMT_SUBAPI="raw"
BIN_NAME_SUBAPI="sub-api"
VERIFY_PATH_SUBAPI="/healthz"
ASSET_AMD64_SUBAPI="sub-api-linux-amd64"
ASSET_ARM64_SUBAPI="sub-api-linux-arm64"
ENV_SUBAPI="Environment=LISTEN_ADDR=127.0.0.1:${DEFAULT_INTERNAL_PORT}\nEnvironment=GOMEMLIMIT=32MiB\n"

# 运行时 profile (由 set_backend_profile 填充, 安装/菜单操作前必须先加载)
BACKEND=""
REPO=""
ASSET_FMT=""
BIN_NAME=""
INTERNAL_PORT=""
VERIFY_PATH=""
SYSTEMD_ENV=""
TMP_FILE=""
EXTRACT_TMP=""

#--------------------------- 输出辅助 ---------------------------#
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_RESET='\033[0m'
msg_ok()   { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
msg_info() { echo -e "${C_BLUE}[提示]${C_RESET} $*"; }
msg_warn() { echo -e "${C_YELLOW}[警告]${C_RESET} $*"; }
msg_err()  { echo -e "${C_RED}[错误]${C_RESET} $*"; }
die()      { msg_err "$*"; exit 1; }

#--------------------------- 基础检查 ---------------------------#
check_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 权限运行: sudo bash $0"
}

# 物理内存总量 (MB)
get_total_mem_mb() {
    awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0"
}

# 根分区剩余空间 (MB)
get_disk_free_mb() {
    df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' || echo "0"
}

# 是否已存在生效中的 Swap (排除 /proc/swaps 表头行)
has_swap() {
    [ "$(grep -c . /proc/swaps 2>/dev/null)" -gt 1 ]
}

# 从状态文件读取已安装后端 (菜单操作启动时自动感知)
get_backend_from_state() {
    [ -f "$BACKEND_STATE" ] && cat "$BACKEND_STATE" 2>/dev/null
}

# 根据 BACKEND 选择 profile, 填充运行时变量
set_backend_profile() {
    case "$BACKEND" in
        subconverter)
            REPO="$REPO_SUBCONVERTER"
            ASSET_FMT="$ASSET_FMT_SUBCONVERTER"
            BIN_NAME="$BIN_NAME_SUBCONVERTER"
            INTERNAL_PORT="$DEFAULT_INTERNAL_PORT"
            VERIFY_PATH="$VERIFY_PATH_SUBCONVERTER"
            SYSTEMD_ENV=""
            TMP_FILE="/tmp/subconverter_pkg.tar.gz"
            EXTRACT_TMP="/opt/.subconverter_tmp"
            ;;
        sub-api)
            REPO="$REPO_SUBAPI"
            ASSET_FMT="$ASSET_FMT_SUBAPI"
            BIN_NAME="$BIN_NAME_SUBAPI"
            INTERNAL_PORT="$DEFAULT_INTERNAL_PORT"
            VERIFY_PATH="$VERIFY_PATH_SUBAPI"
            SYSTEMD_ENV="$(printf '%b' "$ENV_SUBAPI")"
            TMP_FILE="/tmp/sub-api_pkg"
            EXTRACT_TMP="/opt/.sub-api_tmp"
            ;;
        "")
            BACKEND="subconverter"
            set_backend_profile
            ;;
        *)
            die "未知后端: ${BACKEND}, 仅支持 subconverter | sub-api"
            ;;
    esac
}

# 是否已安装本套件 (两个后端任一存在 + Nginx 站点配置)
is_installed() {
    [ -x "${INSTALL_DIR}/${BIN_NAME_SUBCONVERTER}" ] \
        || [ -x "${INSTALL_DIR}/${BIN_NAME_SUBAPI}" ]
    [ -f "${NGINX_CONF}" ]
}

#--------------------------- 交互输入 ---------------------------#
# 端口输入: $1=提示语 $2=默认值, 校验通过后写入全局变量 REPLY_PORT
read_port() {
    local prompt="$1" default="$2" input
    while :; do
        read -r -p "${prompt} [${default}]: " input
        [ -z "$input" ] && input="$default"
        if ! [[ "$input" =~ ^[0-9]+$ ]]; then
            msg_warn "端口必须是纯数字, 请重新输入"
            continue
        fi
        if [ "${#input}" -gt 5 ]; then
            msg_warn "端口范围必须在 1-65535 之间, 请重新输入"
            continue
        fi
        input="$((10#$input))"   # 去除前导零, 按十进制解析
        if [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then
            msg_warn "端口范围必须在 1-65535 之间, 请重新输入"
            continue
        fi
        if [ "$input" -eq "$DEFAULT_INTERNAL_PORT" ]; then
            msg_warn "不能使用后端内部端口 ${DEFAULT_INTERNAL_PORT}, 请重新输入"
            continue
        fi
        REPLY_PORT="$input"
        return 0
    done
}

# 域名输入: $1=提示语 $2=默认值, 校验通过后写入全局变量 REPLY_DOMAIN
read_domain() {
    local prompt="$1" default="$2" input
    while :; do
        read -r -p "${prompt} [${default}]: " input
        [ -z "$input" ] && input="$default"
        if [[ "$input" =~ ^[A-Za-z0-9._*-]+$ ]]; then
            REPLY_DOMAIN="$input"
            return 0
        fi
        msg_warn "域名仅允许 字母/数字/./-/_/* 字符, 请重新输入"
    done
}

#--------------------------- Swap 管理 ---------------------------#
create_swap() {
    if [ -f "$SWAP_FILE" ]; then
        msg_info "${SWAP_FILE} 已存在, 跳过创建"
        return 0
    fi
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=none \
        || die "创建 Swap 文件失败"
    chmod 600 "$SWAP_FILE" || die "设置 Swap 文件权限失败"
    mkswap -f "$SWAP_FILE" >/dev/null 2>&1 || die "格式化 Swap 失败"
    swapon "$SWAP_FILE" 2>/dev/null \
        || { rm -f "$SWAP_FILE"; die "启用 Swap 失败 (当前文件系统可能不支持 Swap 文件)"; }
    if ! grep -q "$SWAP_FSTAB_TAG" /etc/fstab 2>/dev/null; then
        echo "${SWAP_FILE} none swap sw 0 0  # ${SWAP_FSTAB_TAG}" >> /etc/fstab \
            || die "写入 /etc/fstab 失败"
    fi
    msg_ok "已创建并启用 ${SWAP_SIZE_MB}MB 虚拟内存 (${SWAP_FILE})"
}

# 内存 <= 256MB 且无 Swap 时, 交互确认创建虚拟内存
maybe_setup_swap() {
    local mem disk_free ans
    mem="$(get_total_mem_mb)"
    has_swap && return 0
    [ "$mem" -le 256 ] || return 0
    disk_free="$(get_disk_free_mb)"
    echo ""
    msg_warn "检测到物理内存仅为 [${mem}]MB 且无 Swap, 容易导致 OOM 崩溃。"
    [ "$disk_free" -lt 600 ] && msg_warn "当前磁盘仅剩 ${disk_free}MB, 创建 Swap 后空间可能紧张"
    read -r -p "是否创建 ${SWAP_SIZE_MB}MB 轻量虚拟内存?[Y/n] (默认: Y): " ans
    case "$ans" in
        n|N|no|NO) msg_info "已跳过创建 Swap" ;;
        *) create_swap ;;
    esac
}

#--------------------------- 依赖安装 ---------------------------#
install_deps() {
    command -v apt-get >/dev/null 2>&1 || die "未检测到 apt-get, 本脚本仅支持 Debian / Ubuntu"
    command -v systemctl >/dev/null 2>&1 || die "未检测到 systemctl, 本脚本需要 Systemd 环境"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || msg_warn "apt-get update 失败, 尝试继续安装依赖"
    apt-get install -y --no-install-recommends curl wget tar nginx \
        || die "依赖安装失败, 请检查网络或软件源后重试"
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    msg_ok "依赖安装完成, 已清理 apt 缓存释放磁盘"
}

#--------------------------- 程序下载与部署 ---------------------------#
download_pkg() {
    local asset arch
    arch="$(uname -m)"
    case "$BACKEND" in
        subconverter)
            case "$arch" in
                x86_64)  asset="$ASSET_AMD64_SUBCONVERTER" ;;
                aarch64) asset="$ASSET_ARM64_SUBCONVERTER" ;;
                *) die "不支持的 CPU 架构: ${arch} (仅支持 x86_64 / aarch64)" ;;
            esac
            ;;
        sub-api)
            case "$arch" in
                x86_64)  asset="$ASSET_AMD64_SUBAPI" ;;
                aarch64) asset="$ASSET_ARM64_SUBAPI" ;;
                *) die "不支持的 CPU 架构: ${arch} (仅支持 x86_64 / aarch64)" ;;
            esac
            ;;
    esac
    local url="${GH_PROXY}https://github.com/${REPO}/releases/latest/download/${asset}"
    msg_info "下载地址: ${url}"
    local i ok=1
    for i in 1 2 3; do
        rm -f "$TMP_FILE"
        if curl -fSL --connect-timeout 15 --max-time 300 -o "$TMP_FILE" "$url"; then
            ok=0
            break
        fi
        msg_warn "第 ${i}/3 次下载失败"
        [ "$i" -lt 3 ] && sleep 2
    done
    [ "$ok" -eq 0 ] || die "下载失败, 请检查网络后重试 (网络不佳可在脚本顶部 GH_PROXY 填入加速前缀)"
    [ -s "$TMP_FILE" ] || die "下载的文件为空, 已终止"
    if [ "$ASSET_FMT" = "tar.gz" ]; then
        tar -tzf "$TMP_FILE" >/dev/null 2>&1 \
            || die "压缩包校验失败 (可能下载不完整或已损坏), 已终止"
    fi
    msg_ok "下载完成 ($(ls -lh "$TMP_FILE" | awk '{print $5}'))"
}

# 将下载的文件部署到 INSTALL_DIR (tar.gz 解压 / raw 直接落地)
extract_pkg() {
    rm -rf "$INSTALL_DIR" "$EXTRACT_TMP"
    mkdir -p "$INSTALL_DIR"
    if [ "$ASSET_FMT" = "raw" ]; then
        # 裸二进制: 直接重命名落地
        mv "$TMP_FILE" "${INSTALL_DIR}/${BIN_NAME}"
        chmod +x "${INSTALL_DIR}/${BIN_NAME}"
        [ -x "${INSTALL_DIR}/${BIN_NAME}" ] \
            || die "部署后未检测到可执行文件 ${INSTALL_DIR}/${BIN_NAME}"
        msg_ok "已部署到 ${INSTALL_DIR}, 临时文件已清理"
        return 0
    fi
    # tar.gz: 解压 + find + cp (subconverter)
    mkdir -p "$EXTRACT_TMP"
    tar -xzf "$TMP_FILE" -C "$EXTRACT_TMP" \
        || { rm -rf "$EXTRACT_TMP"; die "解压失败, 压缩包可能已损坏"; }
    local bin bindir
    bin="$(find "$EXTRACT_TMP" -type f -name "$BIN_NAME" | head -n 1)"
    if [ -z "$bin" ]; then
        rm -rf "$EXTRACT_TMP"
        die "压缩包内未找到 ${BIN_NAME} 主程序, 已终止"
    fi
    bindir="$(dirname "$bin")"
    cp -a "$bindir/." "$INSTALL_DIR/" \
        || { rm -rf "$EXTRACT_TMP"; die "部署文件到 ${INSTALL_DIR} 失败"; }
    rm -rf "$EXTRACT_TMP"
    chmod +x "${INSTALL_DIR}/${BIN_NAME}"
    rm -f "$TMP_FILE"
    [ -x "${INSTALL_DIR}/${BIN_NAME}" ] \
        || die "部署后未检测到可执行文件 ${INSTALL_DIR}/${BIN_NAME}"
    msg_ok "已部署到 ${INSTALL_DIR}, 临时文件已清理"
}

#--------------------------- 配置文件 ---------------------------#
# Systemd 单元文件 (支持 sub-api 的 Environment 注入)
write_systemd_unit() {
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=${BACKEND} Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/${BIN_NAME}
${SYSTEMD_ENV}Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

# Nginx 站点配置 (引用全局 REPLY_PORT / REPLY_DOMAIN)
write_nginx_conf() {
    mkdir -p /etc/nginx/conf.d
    cat > "$NGINX_CONF" <<'EOF'
server {
    listen {{NGINX_PORT}};
    server_name {{DOMAIN_OR_UNDERSCORE}};

    access_log off;
    error_log /var/log/nginx/sub_error.log crit;

    client_max_body_size 10M;

    location / {
        proxy_pass http://127.0.0.1:{{INTERNAL_PORT}};
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }
}
EOF
    sed -i "s|{{NGINX_PORT}}|${REPLY_PORT}|g" "$NGINX_CONF"
    sed -i "s|{{DOMAIN_OR_UNDERSCORE}}|${REPLY_DOMAIN}|g" "$NGINX_CONF"
    sed -i "s|{{INTERNAL_PORT}}|${INTERNAL_PORT}|g" "$NGINX_CONF"
}

# 从现有配置读取当前监听端口 (无配置返回空)
get_current_port() {
    [ -f "$NGINX_CONF" ] || return 0
    sed -n 's/^[[:space:]]*listen[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' "$NGINX_CONF" | head -n 1
}

# 从现有配置读取当前绑定域名 (无配置返回空)
get_current_domain() {
    [ -f "$NGINX_CONF" ] || return 0
    sed -n 's/^[[:space:]]*server_name[[:space:]]\{1,\}\([^;]\{1,\}\);.*/\1/p' "$NGINX_CONF" | head -n 1
}

#--------------------------- 服务管理 ---------------------------#
start_services() {
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME" \
        || die "后端服务 (${BACKEND}) 启动失败, 可执行: journalctl -u ${SERVICE_NAME} -n 20 排查"
    msg_ok "后端服务已启动 (${BACKEND}, 异常自动拉起: Restart=always)"
    nginx -t || die "Nginx 配置语法检查失败, 已终止"
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx || die "Nginx 启动失败"
    msg_ok "Nginx 已启动并监听端口 ${REPLY_PORT}"
}

# 本地部署验证 (按后端 profile 的 VERIFY_PATH 检查: subconverter /version, sub-api /healthz)
verify_service() {
    sleep 1
    local resp
    resp="$(curl -s --connect-timeout 5 "http://127.0.0.1:${REPLY_PORT}${VERIFY_PATH}" | tr -d '\r\n')"
    if [ -n "$resp" ]; then
        msg_ok "部署验证通过: http://127.0.0.1:${REPLY_PORT}${VERIFY_PATH} -> ${resp}"
    else
        msg_warn "部署验证失败 (${VERIFY_PATH} 无响应), 可执行 journalctl -u ${SERVICE_NAME} -n 20 与 nginx -t 排查"
    fi
}

# 服务启停/重启: $1 = start | stop | restart
svc_action() {
    local action="$1" cn="" rc=0
    case "$action" in
        start)   cn="启动" ;;
        stop)    cn="停止" ;;
        restart) cn="重启" ;;
        *) msg_warn "未知操作: $action"; return 1 ;;
    esac
    if [ "$action" = "stop" ]; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || { msg_err "后端 (${BACKEND}) 停止失败"; rc=1; }
        systemctl stop nginx 2>/dev/null           || { msg_err "nginx 停止失败"; rc=1; }
    else
        systemctl "$action" "$SERVICE_NAME" \
            || { msg_err "后端 (${BACKEND}) ${cn}失败, 可执行: journalctl -u ${SERVICE_NAME} -n 20 排查"; rc=1; }
        if nginx -t >/dev/null 2>&1; then
            systemctl "$action" nginx || { msg_err "nginx ${cn}失败"; rc=1; }
        else
            msg_err "Nginx 配置语法异常, 已跳过 nginx ${cn}, 可执行 nginx -t 查看详情"
            rc=1
        fi
    fi
    [ "$rc" -eq 0 ] && msg_ok "已${cn}所有服务 (后端 ${BACKEND} + Nginx)"
    return "$rc"
}

#--------------------------- 功能选项 ---------------------------#
# 选项 1: 全新安装 / 覆盖安装
do_install() {
    echo ""
    echo "=================================================="
    echo "       NAT VPS 订阅转换后端 安装向导"
    echo "=================================================="
    local mem disk_free cur_port cur_domain go="" backend_choice
    mem="$(get_total_mem_mb)"
    disk_free="$(get_disk_free_mb)"
    msg_info "系统预检: 物理内存 ${mem}MB / 磁盘剩余 ${disk_free}MB / 架构 $(uname -m)"
    if [ "$mem" -lt 128 ] || [ "$disk_free" -lt 150 ]; then
        msg_warn "资源低于建议底线 (内存 >= 128MB, 磁盘剩余 >= 150MB)"
        read -r -p "仍要继续安装吗? [y/N]: " go
        case "$go" in
            y|Y|yes|YES) ;;
            *) msg_info "已取消安装"; return 1 ;;
        esac
    fi
    # 后端选择 (先恢复状态文件再选)
    local saved_backend
    saved_backend="$(get_backend_from_state)"
    [ -z "$saved_backend" ] && saved_backend="subconverter"
    echo ""
    msg_info "请选择订阅转换后端 (回车使用默认 subconverter)"
    msg_warn "sub-api 更轻量 (空闲 <10MB, 单文件 <6MB), 但协议覆盖略少"
    msg_info "subconverter: ss / ssr / vmess / vless / trojan / hy / hy2 / anytls / mieru"
    msg_info "sub-api:      vless+reality / anytls / vmess / ss / trojan / hysteria2"
    read -r -p "后端 [1]subconverter (默认)  [2]sub-api: " backend_choice
    case "$backend_choice" in
        2|sub-api)
            BACKEND="sub-api"
            ;;
        *)
            BACKEND="subconverter"
            ;;
    esac
    set_backend_profile
    msg_ok "已选择后端: ${BACKEND} (内部端口 ${INTERNAL_PORT})"
    maybe_setup_swap
    cur_port="$(get_current_port)";     [ -z "$cur_port" ]   && cur_port="$DEFAULT_NAT_PORT"
    cur_domain="$(get_current_domain)"; [ -z "$cur_domain" ] && cur_domain="_"
    echo ""
    msg_info "请输入 Nginx 本地监听端口 (请填入 NAT 服务商映射给您的内网端口)"
    read_port "监听端口" "$cur_port"
    read_domain "请输入反代绑定的域名 (若仅通过 IP:端口 访问请直接回车)" "$cur_domain"
    echo ""
    msg_info "安装参数: 后端=${BACKEND} / 端口=${REPLY_PORT} / 域名=${REPLY_DOMAIN} / 内部端口=${INTERNAL_PORT}"
    echo ""
    msg_info "[1/5] 安装系统依赖 (curl wget tar nginx)..."
    install_deps
    msg_info "[2/5] 下载 ${BACKEND} 程序 ($(uname -m))..."
    download_pkg
    msg_info "[3/5] 部署到 ${INSTALL_DIR}..."
    extract_pkg
    msg_info "[4/5] 写入 Systemd 服务配置..."
    write_systemd_unit
    msg_info "[5/5] 写入 Nginx 反代配置并启动服务..."
    write_nginx_conf
    start_services
    verify_service
    # 写入状态文件 (菜单操作自动感知)
    echo "$BACKEND" > "$BACKEND_STATE"
    echo ""
    msg_ok "部署完成! 后端: ${BACKEND}"
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$ip" ] && msg_info "本机地址: http://${ip}:${REPLY_PORT}/ (对外请使用 NAT 服务商映射的公网地址)"
    msg_info "部署验证: 浏览器访问 http://<公网地址>:<公网端口>${VERIFY_PATH} 看到后端响应即部署成功"
    msg_info "只能用http://<公网地址>:${REPLY_PORT} 访问, 不能用https://<公网地址>:${REPLY_PORT}/"
}

# 选项 2: 查看服务运行状态与内存占用
do_status() {
    local svc pid rss
    msg_info "当前后端: ${BACKEND} (内部端口 ${INTERNAL_PORT})"
    for svc in "$SERVICE_NAME" nginx; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            pid="$(systemctl show -p MainPID --value "$svc" 2>/dev/null)"
            rss="$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f", $1/1024}')"
            msg_ok "${svc}: 运行中 (PID: ${pid:-未知}, 内存: ${rss:-未知}MB)"
        else
            msg_err "${svc}: 未运行 (当前状态: $(systemctl is-active "$svc" 2>/dev/null || echo unknown))"
        fi
    done
    local cur_port cur_domain
    cur_port="$(get_current_port)"
    cur_domain="$(get_current_domain)"
    [ -n "$cur_port" ] && msg_info "当前反代配置: 监听端口 ${cur_port} / 域名 ${cur_domain:-_}"
    [ -n "$cur_port" ] && msg_info "部署验证: 浏览器访问 http://<公网地址>:${cur_port}${VERIFY_PATH} 看到后端响应即部署成功"
    [ -n "$cur_port" ] && msg_info "只能用http://<公网地址>:${cur_port} 访问, 不能用https://<公网地址>:${cur_port}/"
    echo ""
    free -m 2>/dev/null | sed -n '1,3p'
}

# 选项 6: 修改配置 (NAT 监听端口 / 绑定域名)
do_modify() {
    if [ ! -f "$NGINX_CONF" ]; then
        msg_err "尚未安装本套件, 请先执行安装 (选项 1)"
        return 1
    fi
    local cur_port cur_domain
    cur_port="$(get_current_port)"
    cur_domain="$(get_current_domain)"
    msg_info "当前配置: 端口=${cur_port:-未知} / 域名=${cur_domain:-_}"
    echo ""
    read_port "新监听端口 (回车保持当前值)" "${cur_port:-$DEFAULT_NAT_PORT}"
    read_domain "新绑定域名 (回车保持当前值)" "${cur_domain:-_}"
    cp "$NGINX_CONF" "${NGINX_CONF}.bak" || die "备份原配置失败"
    write_nginx_conf
    if nginx -t; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
        rm -f "${NGINX_CONF}.bak"
        msg_ok "配置已生效: 端口=${REPLY_PORT} / 域名=${REPLY_DOMAIN}"
    else
        mv -f "${NGINX_CONF}.bak" "$NGINX_CONF"
        msg_err "新配置语法检查失败, 已回滚为原配置"
        return 1
    fi
}

# 选项 7: 一键完全卸载
do_uninstall() {
    if ! is_installed && [ ! -f "$SYSTEMD_UNIT" ]; then
        msg_warn "未检测到本套件, 无需卸载"
        return 1
    fi
    local ans=""
    echo ""
    msg_warn "即将完全卸载: 停止并禁用服务 / 删除 ${INSTALL_DIR} / 删除 Nginx 站点配置 / 移除脚本创建的 Swap / 清理后端状态文件"
    read -r -p "确认完全卸载? [y/N]: " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) msg_info "已取消卸载"; return 1 ;;
    esac
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1
    systemctl disable --now nginx >/dev/null 2>&1
    rm -rf "$INSTALL_DIR"
    rm -f "$NGINX_CONF" "${NGINX_CONF}.bak" "$SYSTEMD_UNIT" "$BACKEND_STATE"
    if grep -q "$SWAP_FSTAB_TAG" /etc/fstab 2>/dev/null; then
        swapoff "$SWAP_FILE" 2>/dev/null
        rm -f "$SWAP_FILE"
        sed -i "\#${SWAP_FSTAB_TAG}#d" /etc/fstab
        msg_ok "已移除脚本创建的虚拟内存 (${SWAP_FILE})"
    fi
    systemctl daemon-reload
    msg_ok "卸载完成, 相关文件与配置已彻底清理 (nginx 软件包已保留, 如需删除请执行: apt-get purge nginx)"
}

# 更新失败回滚: 恢复备份的旧程序并启动
_update_rollback() {
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    rm -rf "$INSTALL_DIR" "$EXTRACT_TMP"
    if [ -d "${INSTALL_DIR}.bak" ]; then
        mv "${INSTALL_DIR}.bak" "$INSTALL_DIR"
        if systemctl start "$SERVICE_NAME" 2>/dev/null; then
            msg_ok "已回滚到旧版本, 服务已恢复"
        else
            msg_err "已回滚旧程序但服务启动失败, 请执行: journalctl -u ${SERVICE_NAME} -n 20 排查"
        fi
    else
        msg_err "备份目录不存在, 无法自动回滚"
    fi
}

# 选项 8: 更新后端程序 (仅替换程序本体, 端口/域名等配置不动)
do_update() {
    if ! is_installed; then
        msg_err "尚未安装本套件, 请先执行安装 (选项 1)"
        return 1
    fi
    local old_resp new_resp ans
    old_resp="$(curl -s --connect-timeout 3 "http://127.0.0.1:${INTERNAL_PORT}${VERIFY_PATH}" | tr -d '\r\n')"
    echo ""
    msg_info "当前后端: ${BACKEND}"
    msg_info "当前${VERIFY_PATH}响应: ${old_resp:-无法获取 (服务未运行?)}"
    read -r -p "下载最新版并替换程序? (端口/域名等配置不变, 服务将中断约 2-3 秒) [y/N]: " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) msg_info "已取消更新"; return 1 ;;
    esac
    msg_info "[1/4] 下载最新 ${BACKEND} 程序包 ($(uname -m))..."
    download_pkg
    msg_info "[2/4] 备份旧程序并替换文件..."
    systemctl stop "$SERVICE_NAME"
    rm -rf "${INSTALL_DIR}.bak"
    mv "$INSTALL_DIR" "${INSTALL_DIR}.bak" \
        || { systemctl start "$SERVICE_NAME"; rm -rf "$EXTRACT_TMP"; die "备份旧程序失败, 已取消更新"; }
    local ok=1 new_bin
    mkdir -p "$INSTALL_DIR"
    if [ "$ASSET_FMT" = "raw" ]; then
        # 裸二进制: 直接落地
        if mv "$TMP_FILE" "${INSTALL_DIR}/${BIN_NAME}" \
            && chmod +x "${INSTALL_DIR}/${BIN_NAME}" \
            && [ -x "${INSTALL_DIR}/${BIN_NAME}" ]; then
            ok=0
        fi
    else
        # tar.gz: 解压 + find + cp
        mkdir -p "$EXTRACT_TMP"
        if tar -xzf "$TMP_FILE" -C "$EXTRACT_TMP" 2>/dev/null; then
            new_bin="$(find "$EXTRACT_TMP" -type f -name "$BIN_NAME" | head -n 1)"
            if [ -n "$new_bin" ]; then
                if cp -a "$(dirname "$new_bin")/." "$INSTALL_DIR/" \
                    && chmod +x "${INSTALL_DIR}/${BIN_NAME}" \
                    && [ -x "${INSTALL_DIR}/${BIN_NAME}" ]; then
                    ok=0
                fi
            else
                rm -rf "$EXTRACT_TMP"
                msg_err "压缩包内未找到 ${BIN_NAME} 主程序"
            fi
        else
            rm -rf "$EXTRACT_TMP"
            msg_err "解压失败, 压缩包可能已损坏"
        fi
    fi
    rm -rf "$EXTRACT_TMP"
    if [ "$ok" -eq 0 ] && systemctl start "$SERVICE_NAME" 2>/dev/null; then
        sleep 1
        new_resp="$(curl -s --connect-timeout 5 "http://127.0.0.1:${INTERNAL_PORT}${VERIFY_PATH}" | tr -d '\r\n')"
        if [ -n "$new_resp" ]; then
            rm -rf "${INSTALL_DIR}.bak"
            rm -f "$TMP_FILE"
            msg_ok "更新完成: ${BACKEND} ${old_resp:-旧版本} -> ${new_resp:-新版本}"
            [ "$old_resp" = "$new_resp" ] && msg_info "响应未变化, 可能已是最新版本"
        else
            msg_err "新版本验证失败 (${VERIFY_PATH} 无响应), 正在回滚..."
            _update_rollback
            return 1
        fi
    else
        msg_err "新版本部署或启动失败, 正在回滚..."
        _update_rollback
        return 1
    fi
}

#--------------------------- 主菜单 ---------------------------#
show_menu() {
    echo ""
    echo "=================================================="
    echo "   NAT VPS 订阅转换后端 极简管理脚本"
    echo "=================================================="
    echo " 当前后端: ${BACKEND:-subconverter}"
    echo "--------------------------------------------------"
    echo " 1. 全新安装 / 覆盖安装 (可选后端)"
    echo " 2. 查看服务运行状态与内存占用"
    echo " 3. 启动所有服务 (后端 + Nginx)"
    echo " 4. 停止所有服务"
    echo " 5. 重启所有服务"
    echo " 6. 修改配置 (NAT监听端口 / 绑定域名)"
    echo " 7. 一键完全卸载 (清理所有文件与配置)"
    echo " 8. 更新后端程序"
    echo " 0. 退出脚本"
    echo "=================================================="
}

main() {
    [ -n "$BASH_VERSION" ] || { echo "请使用 bash 运行: bash $0"; exit 1; }
    check_root
    # 启动时从状态文件恢复后端 profile, 让菜单操作自动感知已装后端
    local saved
    saved="$(get_backend_from_state)"
    if [ -n "$saved" ]; then
        BACKEND="$saved"
        set_backend_profile
    else
        # 无状态文件 -> 尝试探测已有二进制
        if [ -x "${INSTALL_DIR}/${BIN_NAME_SUBCONVERTER}" ]; then
            BACKEND="subconverter"
            set_backend_profile
        elif [ -x "${INSTALL_DIR}/${BIN_NAME_SUBAPI}" ]; then
            BACKEND="sub-api"
            set_backend_profile
        else
            # 全新场景, 默认 subconverter
            BACKEND="subconverter"
            set_backend_profile
        fi
    fi
    if ! is_installed; then
        msg_info "检测到尚未安装本套件, 即将进入安装向导..."
        do_install
    fi
    while :; do
        show_menu
        local choice=""
        read -r -p "请输入选项编号 [0-8]: " choice
        case "$choice" in
            1) do_install ;;
            2) do_status ;;
            3) svc_action start ;;
            4) svc_action stop ;;
            5) svc_action restart ;;
            6) do_modify ;;
            7) do_uninstall ;;
            8) do_update ;;
            0) msg_info "再见"; exit 0 ;;
            *) msg_warn "无效选项, 请输入 0-8" ;;
        esac
        echo ""
        read -r -p "按回车键返回主菜单..." _
    done
}

main "$@"
