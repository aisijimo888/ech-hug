#!/bin/bash
set -e

# ================= Argo 环境变量（JS 等价） =================
ARGO_DOMAIN="${ARGO_DOMAIN:-}"        # 固定隧道域名（留空 = 临时隧道）
ARGO_AUTH="${ARGO_AUTH:-}"            # token 或 credentials.json 内容
ARGO_PORT="${ARGO_PORT:-8001}"        # 固定隧道端口
# ===========================================================

# ================= 工具函数 =================
get_free_port() {
    echo $(( ( RANDOM % 20000 ) + 10000 ))
}

# ================= 主函数 =================
quicktunnel() {
    echo "--- 设置 DNS ---"
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
            echo "不支持的架构: $ARCH"
            exit 1
            ;;
    esac

    curl -fsSL "$ECH_URL" -o ech-server
    curl -fsSL "$OPERA_URL" -o opera
    curl -fsSL "$CLOUDFLARED_URL" -o cloudflared
    chmod +x ech-server opera cloudflared

    echo "--- 端口分配 ---"
    WSPORT=${WSPORT:-$(get_free_port)}
    ECHPORT=$((WSPORT + 1))
    export WSPORT ECHPORT

    echo "Caddy: $WSPORT"
    echo "ECH:   $ECHPORT"

    # ========== Opera ==========
    if [ "${OPERA:-0}" = "1" ]; then
        operaport=$(get_free_port)
        COUNTRY=${COUNTRY:-AM}
        nohup ./opera -country "$COUNTRY" -socks-mode \
            -bind-address "127.0.0.1:$operaport" >/dev/null 2>&1 &
    fi

    # ========== ECH ==========
    ECH_ARGS=(./ech-server -l "ws://0.0.0.0:$ECHPORT")
    [ -n "$TOKEN" ] && ECH_ARGS+=(-token "$TOKEN")
    [ "${OPERA:-0}" = "1" ] && ECH_ARGS+=(-f "socks5://127.0.0.1:$operaport")
    nohup "${ECH_ARGS[@]}" >/dev/null 2>&1 &

    # ========== Cloudflared ==========
    metricsport=$(get_free_port)

    USE_FIXED_ARGO=0
    if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
        USE_FIXED_ARGO=1
    fi

    if [ "$USE_FIXED_ARGO" = "1" ]; then
        echo "--- 使用固定 Argo 隧道 ---"

        if echo "$ARGO_AUTH" | grep -q '{'; then
            mkdir -p /root/.cloudflared
            echo "$ARGO_AUTH" > /root/.cloudflared/argo.json
            AUTH_ARGS=(--credentials-file /root/.cloudflared/argo.json)
        else
            AUTH_ARGS=(--token "$ARGO_AUTH")
        fi

        nohup ./cloudflared tunnel run \
            "${AUTH_ARGS[@]}" \
            --edge-ip-version "${IPS:-4}" \
            --protocol http2 \
            --url "http://127.0.0.1:$ARGO_PORT" \
            --metrics "127.0.0.1:$metricsport" \
            >/dev/null 2>&1 &
    else
        echo "--- 使用临时 Argo 隧道 ---"
        nohup ./cloudflared \
            --edge-ip-version "${IPS:-4}" \
            --protocol http2 \
            tunnel --url "127.0.0.1:$ECHPORT" \
            --metrics "127.0.0.1:$metricsport" \
            >/dev/null 2>&1 &
    fi

    # ========== HTML 信息页 ==========
    HTTP_DIR="/opt/argo"
    mkdir -p "$HTTP_DIR"

    cat > "$HTTP_DIR/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="zh-TW">
<head>
<meta charset="UTF-8">
<title>Argo Info</title>
<style>
body{background:#020617;color:#e5e7eb;display:flex;justify-content:center;align-items:center;height:100vh;font-family:system-ui}
.box{background:#020617;padding:24px 32px;border-radius:12px}
.domain{color:#38bdf8;font-size:20px;margin-top:8px}
</style>
</head>
<body>
<div class="box">
<h2 id="s">等待 Argo…</h2>
<div class="domain" id="d"></div>
</div>
<script src="info.js"></script>
<script>
if(window.CONN_INFO){
  s.innerText="Argo 已就绪";
  d.innerText=window.CONN_INFO;
}
</script>
</body>
</html>
EOF

    (
    LAST=""
    while true; do
        if [ "$USE_FIXED_ARGO" = "1" ]; then
            DOMAIN="$ARGO_DOMAIN"
        else
            RESP=$(curl -s "http://127.0.0.1:$metricsport/metrics" || true)
            DOMAIN=$(echo "$RESP" | grep 'userHostname="' | head -n1 \
                | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' || true)
        fi

        if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "$LAST" ]; then
            echo "window.CONN_INFO=\"連接為: ${DOMAIN}:443\";" > "$HTTP_DIR/info.js"
            LAST="$DOMAIN"
        fi
        sleep 5
    done
    ) &
}

# ================= main =================
quicktunnel

echo "--- 启动 Caddy（$WSPORT）---"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
