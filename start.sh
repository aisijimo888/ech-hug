#!/bin/sh
set -e

# ================= 配置 =================
ARGO_DOMAIN="${ARGO_DOMAIN:-}"    # 固定隧道域名，留空 = 临时隧道
ARGO_AUTH="${ARGO_AUTH:-}"        # 直接 JSON 凭证内容
ARGO_PORT="${ARGO_PORT:-8001}"    # Cloudflared metrics 端口
IPS="${IPS:-4}"                   # IP 版本
OPERA="${OPERA:-0}"               # Opera 代理开关 0/1
COUNTRY="${COUNTRY:-AM}"          # Opera 国家默认 AM

# ================= 工具 =================
get_free_port() {
    echo $(( ( RANDOM % 20000 ) + 10000 ))
}

# ================= 启动 Tunnel =================
quicktunnel() {
    echo "--- 强制 DNS 为 1.1.1.1 / 1.0.0.1 ---"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 1.0.0.1" >> /etc/resolv.conf

    echo "--- 下载二进制 ---"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-amd64"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-amd64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        i386|i686)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-386"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-386"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386"
            ;;
        arm64|aarch64)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-arm64"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-arm64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        *)
            echo "❌ 不支持的架构: $ARCH"
            exit 1
            ;;
    esac

    curl -fsSL "$ECH_URL" -o ech-server-linux
    curl -fsSL "$OPERA_URL" -o opera-linux
    curl -fsSL "$CLOUDFLARED_URL" -o cloudflared-linux
    chmod +x ech-server-linux opera-linux cloudflared-linux

    # ================= 端口 =================
    WSPORT=${WSPORT:-$(get_free_port)}
    ECHPORT=$((WSPORT + 1))

    echo "--- 分配端口 ---"
    echo "WS:  $WSPORT"
    echo "ECH: $ECHPORT"

    # ================= Opera =================
    if [ "$OPERA" = "1" ]; then
        COUNTRY=$(echo "$COUNTRY" | tr 'a-z' 'A-Z')
        operaport=$(get_free_port)
        echo "启动 Opera Proxy (port:$operaport, country:$COUNTRY)"
        nohup ./opera-linux -country "$COUNTRY" -socks-mode \
            -bind-address "127.0.0.1:$operaport" >/dev/null 2>&1 &
        OPERA_PID=$!
    fi

    # ================= ECH =================
    sleep 1
    ECH_ARGS="./ech-server-linux -l ws://0.0.0.0:$ECHPORT"

    [ -n "$TOKEN" ] && ECH_ARGS="$ECH_ARGS -token $TOKEN"
    [ "$OPERA" = "1" ] && ECH_ARGS="$ECH_ARGS -f socks5://127.0.0.1:$operaport"

    echo "启动 ECH Server..."
    nohup sh -c "$ECH_ARGS" >/dev/null 2>&1 &
    ECH_PID=$!

    i=0
    while [ $i -lt 15 ]; do
        nc -z 127.0.0.1 "$ECHPORT" 2>/dev/null && break
        sleep 1
        i=$((i+1))
    done

    if [ $i -eq 15 ]; then
        echo "❌ ECH 未监听端口 $ECHPORT"
        exit 1
    fi

    # ================= Cloudflared =================
    echo "--- 启动 Cloudflared ---"
    CLOUDFLARED_LOG="/tmp/cloudflared.log"
    ARGO_ARGS="--protocol http2"

    if [ -n "$ARGO_AUTH" ]; then
        ARGO_AUTH_FILE="/tmp/argo_auth.json"
        echo "$ARGO_AUTH" > "$ARGO_AUTH_FILE"
        chmod 600 "$ARGO_AUTH_FILE"
        ARGO_ARGS="$ARGO_ARGS --credentials-file $ARGO_AUTH_FILE"
    fi

    [ -n "$ARGO_DOMAIN" ] && ARGO_ARGS="$ARGO_ARGS --hostname $ARGO_DOMAIN"

    nohup ./cloudflared-linux tunnel \
        --url "127.0.0.1:$ECHPORT" \
        --metrics "0.0.0.0:$ARGO_PORT" \
        $ARGO_ARGS >"$CLOUDFLARED_LOG" 2>&1 &

    CF_PID=$!
    sleep 3

    if ! kill -0 "$CF_PID" 2>/dev/null; then
        echo "❌ Cloudflared 启动失败"
        cat "$CLOUDFLARED_LOG"
        exit 1
    fi
}

# ================= 获取域名 =================
get_tunnel_domain() {
    if [ -n "$ARGO_DOMAIN" ]; then
        TUNNEL_DOMAIN="$ARGO_DOMAIN"
        echo "✓ 使用固定域名: $TUNNEL_DOMAIN"
        return
    fi

    echo "--- 获取临时隧道域名 ---"
    for i in $(seq 1 30); do
        TUNNEL_DOMAIN=$(curl -s "http://127.0.0.1:$ARGO_PORT/metrics" \
            | grep 'userHostname=' \
            | sed -E 's/.*userHostname="([^"]+)".*/\1/')
        [ -n "$TUNNEL_DOMAIN" ] && break
        sleep 1
    done

    if [ -z "$TUNNEL_DOMAIN" ]; then
        echo "❌ 获取临时域名失败"
        exit 1
    fi

    echo "✓ 隧道域名: $TUNNEL_DOMAIN"
}

# ================= 页面 =================
write_index_html() {
    mkdir -p /srv
    cat > /srv/index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>Tunnel Ready</title>
</head>
<body style="background:#020617;color:#e5e7eb;display:flex;align-items:center;justify-content:center;height:100vh">
<div>
<h1>🚀 Tunnel 已就绪</h1>
<p>$TUNNEL_DOMAIN</p>
</div>
</body>
</html>
EOF
}

# ================= main =================
quicktunnel
get_tunnel_domain
write_index_html

echo "--- 启动 Caddy ---"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
