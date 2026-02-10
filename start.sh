#!/bin/sh
set -e

# ================= 配置 =================
ARGO_DOMAIN="${ARGO_DOMAIN:-}"    # 固定隧道域名，留空 = 临时隧道
ARGO_AUTH="${ARGO_AUTH:-}"        # 直接 JSON 凭证内容
ARGO_PORT="${ARGO_PORT:-8001}"    # Cloudflared metrics 端口
IPS="${IPS:-4}"                   # IP 版本
OPERA="${OPERA:-0}"               # Opera 代理开关 0/1
COUNTRY="${COUNTRY:-AM}"          # Opera 国家默认 AM

# 随机端口
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
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-amd64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        i386|i686)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-386"
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-386"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386"
            ;;
        arm64|aarch64)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-arm64"
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-arm64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        *)
            echo "架构 $ARCH 不支持"
            exit 1
            ;;
    esac

    curl -fL "$ECH_URL" -o ech-server-linux
    curl -fL "$OPERA_URL" -o opera-linux
    curl -fL "$CLOUDFLARED_URL" -o cloudflared-linux
    chmod +x ech-server-linux opera-linux cloudflared-linux

    # ================= 端口分配 =================
    WSPORT=${WSPORT:-$(get_free_port)}
    ECHPORT=$((WSPORT + 1))
    echo "--- 分配端口 ---"
    echo "Caddy: $WSPORT"
    echo "ECH:   $ECHPORT"

    # ================= Opera =================
    if [ "$OPERA" = "1" ]; then
        COUNTRY=$(echo "$COUNTRY" | tr 'a-z' 'A-Z')
        operaport=$(get_free_port)
        echo "启动 Opera Proxy (port:$operaport, country:$COUNTRY)..."
        nohup ./opera-linux -country "$COUNTRY" -socks-mode -bind-address "127.0.0.1:$operaport" >/dev/null 2>&1 &
        OPERA_PID=$!
    fi

    # ================= ECH =================
    sleep 1
    ECH_ARGS="./ech-server-linux -l ws://0.0.0.0:$ECHPORT"
    if [ -n "$TOKEN" ]; then
        ECH_ARGS="$ECH_ARGS -token $TOKEN"
    fi
    if [ "$OPERA" = "1" ]; then
        ECH_ARGS="$ECH_ARGS -f socks5://127.0.0.1:$operaport"
    fi
    echo "启动 ECH Server..."
    nohup sh -c "$ECH_ARGS" >/dev/null 2>&1 &
    ECH_PID=$!

    # 等待 ECH 监听端口
    i=0
    while [ $i -lt 15 ]; do
        if nc -z 127.0.0.1 $ECHPORT 2>/dev/null; then
            echo "✓ ECH 已监听端口 $ECHPORT"
            break
        fi
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
    if [ -n "$ARGO_DOMAIN" ]; then
        ARGO_ARGS="$ARGO_ARGS --hostname $ARGO_DOMAIN"
    fi

    nohup ./cloudflared-linux tunnel --url "127.0.0.1:$ECHPORT" --metrics "0.0.0.0:$ARGO_PORT" $ARGO_ARGS > "$CLOUDFLARED_LOG" 2>&1 &
    CF_PID=$!
    sleep 3

    if ! kill -0 $CF_PID 2>/dev/null; then
        echo "❌ Cloudflared 启动失败，日志:"
        cat "$CLOUDFLARED_LOG"
        exit 1
    fi

    # ================= 临时 / 固定域名 =================
get_tunnel_domain() {
    if [ -z "$ARGO_DOMAIN" ]; then
        echo "--- 获取临时隧道域名 ---"
        TUNNEL_DOMAIN=""

        for i in $(seq 1 30); do
            TUNNEL_DOMAIN=$(curl -s "http://127.0.0.1:$ARGO_PORT/metrics" 2>/dev/null \
                | grep 'userHostname=' \
                | sed -E 's/.*userHostname="([^"]+)".*/\1/')

            if [ -n "$TUNNEL_DOMAIN" ]; then
                echo "✓ 隧道启动成功，域名: $TUNNEL_DOMAIN"
                break
            fi
            sleep 1
        done

        if [ -z "$TUNNEL_DOMAIN" ]; then
            echo "❌ 获取临时域名失败"
            tail -20 "$CLOUDFLARED_LOG"
            exit 1
        fi
    else
        TUNNEL_DOMAIN="$ARGO_DOMAIN"
        echo "✓ 使用固定域名: $TUNNEL_DOMAIN"
    fi
}

# ================= 写入 index.html =================
write_index_html() {
    mkdir -p /srv

    cat > /srv/index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>Cloudflare Tunnel</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            background: #0f172a;
            color: #e5e7eb;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
        }
        .box {
            background: #020617;
            padding: 30px 40px;
            border-radius: 10px;
            box-shadow: 0 0 20px rgba(0,0,0,.5);
            text-align: center;
        }
        .domain {
            font-size: 20px;
            color: #38bdf8;
            margin-top: 10px;
            word-break: break-all;
        }
    </style>
</head>
<body>
    <div class="box">
        <h1>🚀 Tunnel 已就绪</h1>
        <div class="domain">$TUNNEL_DOMAIN</div>
    </div>
</body>
</html>
EOF

    echo "✓ 域名已写入 /srv/index.html"
}

# ================= 执行 =================
get_tunnel_domain
write_index_html


# ================= main =================
quicktunnel

echo "--- 启动 Caddy 前台服务 ---"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
