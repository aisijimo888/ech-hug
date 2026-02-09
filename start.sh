#!/bin/bash
set -e

# ================= 环境变量 =================
ARGO_PORT="${ARGO_PORT:-8001}"        # metrics 端口
ARGO_AUTH="${ARGO_AUTH:-eyJhIjoiYWJmZGRiMGY3NzdmYzQzZDhjOGJlZmY4Zjc1MTE5YzEiLCJ0IjoiYWYwMDMxZTQtNmE5Ni00ZjNmLThkN2ItOGNiOGVlMTQ4NmFhIiwicyI6IlpqVXpOMk5qTXpBdFpERXdNaTAwWm1FMUxUZ3paV010TkRnd01UWmlObVF4TWpFMSJ9}"            # tunnel credentials.json 内容
TUNNEL_NAME="${TUNNEL_NAME:-ech-koyeb}"        # Tunnel 名字（不是域名）

IPS="${IPS:-4}"
OPERA="${OPERA:-0}"
COUNTRY="${COUNTRY:-AM}"

# ================= 工具函数 =================
get_free_port() {
    echo $(( ( RANDOM % 20000 ) + 10000 ))
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
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-arm64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        *)
            echo "不支持的架构: $ARCH"
            exit 1
            ;;
    esac

    curl -fsSL "$ECH_URL" -o ech-server
    curl -fsSL "$OPERA_URL" -o opera
    curl -fsSL "$CLOUDFLARED_URL" -o cloudflared

    chmod +x ech-server opera cloudflared

    echo "--- 分配端口 ---"
    WSPORT=${WSPORT:-$(get_free_port)}
    ECHPORT=$((WSPORT + 1))

    export WSPORT ECHPORT
    echo "Caddy: $WSPORT"
    echo "ECH:   $ECHPORT"

    # ================= Opera Proxy =================
    if [ "$OPERA" = "1" ]; then
        COUNTRY="${COUNTRY^^}"
        operaport=$(get_free_port)

        echo "启动 Opera Proxy ($COUNTRY) @ $operaport"
        nohup ./opera \
            -country "$COUNTRY" \
            -socks-mode \
            -bind-address "127.0.0.1:$operaport" \
            > /dev/null 2>&1 &
    fi

    sleep 1

    # ================= ECH =================
    ECH_ARGS=(./ech-server -l "ws://0.0.0.0:$ECHPORT")

    if [ -n "$TOKEN" ]; then
        ECH_ARGS+=(-token "$TOKEN")
    fi

    if [ "$OPERA" = "1" ]; then
        ECH_ARGS+=(-f "socks5://127.0.0.1:$operaport")
    fi

    echo "启动 ECH Server..."
    nohup "${ECH_ARGS[@]}" > /tmp/ech.log 2>&1 &

    # ================= 检查 ECH 端口 =================
    echo "等待 ECH 监听端口 $ECHPORT..."
    ECH_OK=0
    for i in {1..15}; do
        if bash -c "</dev/tcp/127.0.0.1/$ECHPORT" >/dev/null 2>&1; then
            ECH_OK=1
            break
        fi
        sleep 1
    done

    if [ "$ECH_OK" != "1" ]; then
        echo "❌ ECH 在 15 秒内未监听端口 $ECHPORT"
        echo "ECH 日志："
        tail -20 /tmp/ech.log
        exit 1
    fi
    echo "✓ ECH 已成功监听端口 $ECHPORT"

    # ================= Cloudflared =================
    if [ -z "$ARGO_AUTH" ] || [ -z "$TUNNEL_NAME" ]; then
        echo "❌ 必须设置 ARGO_AUTH 和 TUNNEL_NAME"
        exit 1
    fi

    echo "--- 启动固定 Cloudflare Tunnel ---"
    CLOUDFLARED_LOG="/tmp/cloudflared.log"
    ARGO_AUTH_FILE="/tmp/argo_auth.json"
    CF_CONFIG="/tmp/cloudflared.yml"

    echo "$ARGO_AUTH" > "$ARGO_AUTH_FILE"
    chmod 600 "$ARGO_AUTH_FILE"

    cat > "$CF_CONFIG" <<EOF
tunnel: $TUNNEL_NAME
credentials-file: $ARGO_AUTH_FILE

protocol: http2
metrics: 0.0.0.0:$ARGO_PORT

ingress:
  - service: http://127.0.0.1:$ECHPORT
  - service: http_status:404
EOF

    nohup ./cloudflared tunnel run \
        --config "$CF_CONFIG" \
        > "$CLOUDFLARED_LOG" 2>&1 &

    CF_PID=$!
    sleep 3

    if ! kill -0 $CF_PID 2>/dev/null; then
        echo "❌ Cloudflared 启动失败"
        tail -50 "$CLOUDFLARED_LOG"
        exit 1
    fi

    echo "✓ Cloudflare Tunnel 已连接 (PID $CF_PID)"
}

# ================= 参数校验 =================
if [ "$IPS" != "4" ] && [ "$IPS" != "6" ]; then
    echo "❌ IPS 只能是 4 或 6"
    exit 1
fi

if [ "$OPERA" != "0" ] && [ "$OPERA" != "1" ]; then
    echo "❌ OPERA 只能是 0 或 1"
    exit 1
fi

quicktunnel

echo "--- 启动 Caddy 前台 (port: $WSPORT) ---"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
