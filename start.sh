#!/bin/bash
set -e

# ================= 工具函数 =================
get_free_port() {
    echo $(( ( RANDOM % 20000 ) + 10000 ))
}

# ================= 核心逻辑 =================
quicktunnel() {
    echo "--- 正在強制設定 DNS 為 1.1.1.1/1.0.0.1 ---"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 1.0.0.1" >> /etc/resolv.conf

    echo "--- 正在下載服務二進制文件 ---"

    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64|x64|amd64)
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
            echo "不支持的架構: $ARCH"
            exit 1
            ;;
    esac

    curl -fsSL "$ECH_URL" -o ech-server-linux
    curl -fsSL "$OPERA_URL" -o opera-linux
    curl -fsSL "$CLOUDFLARED_URL" -o cloudflared-linux
    chmod +x ech-server-linux opera-linux cloudflared-linux

    # ========== 端口 ==========
    WSPORT=${WSPORT:-$(get_free_port)}
    ECHPORT=$((WSPORT + 1))
    export WSPORT ECHPORT

    echo "Caddy 端口: $WSPORT"
    echo "ECH 端口: $ECHPORT"

    # ========== Opera ==========
    if [ "$OPERA" = "1" ]; then
        operaport=$(get_free_port)
        COUNTRY=${COUNTRY:-AM}
        echo "啟動 Opera Proxy ($COUNTRY)"
        nohup ./opera-linux -country "$COUNTRY" -socks-mode \
            -bind-address "127.0.0.1:$operaport" >/dev/null 2>&1 &
    fi

    # ========== ECH ==========
    ECH_ARGS=(./ech-server-linux -l "ws://0.0.0.0:$ECHPORT")
    [ -n "$TOKEN" ] && ECH_ARGS+=(-token "$TOKEN")
    [ "$OPERA" = "1" ] && ECH_ARGS+=(-f "socks5://127.0.0.1:$operaport")

    nohup "${ECH_ARGS[@]}" >/dev/null 2>&1 &
    echo "ECH Server 已啟動"

    # ========== Cloudflared ==========
    metricsport=$(get_free_port)
    echo "Cloudflared metrics 端口: $metricsport"

    nohup ./cloudflared-linux \
        --edge-ip-version "$IPS" \
        --protocol http2 \
        tunnel --url "127.0.0.1:$ECHPORT" \
        --metrics "127.0.0.1:$metricsport" \
        >/dev/null 2>&1 &

    echo "Cloudflared 已啟動"

    # ========== HTML + Argo 域名 ==========
    HTTP_DIR="/opt/argo"
    mkdir -p "$HTTP_DIR"

    if [ ! -f "$HTTP_DIR/index.html" ]; then
cat > "$HTTP_DIR/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="zh-TW">
<head>
<meta charset="UTF-8">
<title>Argo 連接資訊</title>
<style>
body {
  background:#020617;
  color:#e5e7eb;
  font-family:system-ui;
  display:flex;
  justify-content:center;
  align-items:center;
  height:100vh;
}
.box {
  background:#020617;
  padding:24px 32px;
  border-radius:12px;
}
.domain { color:#38bdf8; font-size:20px; margin-top:8px; }
</style>
</head>
<body>
<div class="box">
  <h2 id="status">等待 Argo…</h2>
  <div class="domain" id="conn"></div>
</div>
<script src="info.js"></script>
<script>
if (window.CONN_INFO) {
  document.getElementById("status").innerText = "Argo 已就緒";
  document.getElementById("conn").innerText = window.CONN_INFO;
}
</script>
</body>
</html>
EOF
    fi

    (
    LAST_DOMAIN=""
    while true; do
        RESP=$(curl -s "http://127.0.0.1:$metricsport/metrics" || true)
        DOMAIN=$(echo "$RESP" | grep 'userHostname="' | head -n1 \
            | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' || true)

        if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "$LAST_DOMAIN" ]; then
            echo "Argo 域名: $DOMAIN"
            echo "window.CONN_INFO = \"連接為: ${DOMAIN}:443\";" > "$HTTP_DIR/info.js"
            echo "window.UPDATE_TIME = \"$(date '+%F %T')\";" >> "$HTTP_DIR/info.js"
            LAST_DOMAIN="$DOMAIN"
        fi
        sleep 5
    done
    ) &
}

# ================= main =================
MODE="${1:-1}"

if [ "$MODE" = "1" ]; then
    quicktunnel
else
    echo "未知模式"
    exit 1
fi

echo "--- 啟動 Caddy（port: $WSPORT）---"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
