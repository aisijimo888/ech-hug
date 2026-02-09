#!/bin/bash
set -e

# ================= 环境变量 =================
ARGO_AUTH="${ARGO_AUTH:-}"        # JSON 内容，必填
ARGO_PORT="${ARGO_PORT:-8001}"    # Cloudflared metrics
IPS="${IPS:-4}"                   # 4 或 6
OPERA="${OPERA:-0}"               # 0 或 1
COUNTRY="${COUNTRY:-AM}"          # Opera 代理国家
TOKEN="${TOKEN:-}"                # 可选 ECH token

# ================= 工具函数 =================
get_free_port() {
    echo $(( ( RANDOM % 20000 ) + 10000 ))
}

wait_port() {
    local host=$1
    local port=$2
    local retries=${3:-15}
    for i in $(seq 1 $retries); do
        if bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ================= 主逻辑 =================
quicktunnel() {
    echo "--- 强制 DNS 为 1.1.1.1 / 1.0.0.1 ---"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 1.0.0.1" >> /etc/resolv.conf

    echo "--- 下载二进制 ---"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-amd64"
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-amd64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        aarch64|arm64)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-arm64"
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-arm64"_
