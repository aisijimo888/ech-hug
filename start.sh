#!/bin/bash
set -e

# ================= Argo 环境变量（JS 等价） =================
ARGO_DOMAIN="${ARGO_DOMAIN:-}"        # 固定隧道域名（留空 = 临时隧道）
ARGO_AUTH="${ARGO_AUTH:-}"            # token 或 credentials.json 内容
ARGO_PORT="${ARGO_PORT:-8001}"        # 固定隧道端口
IPS="${IPS:-4}"                       # ← 添加默认值
OPERA="${OPERA:-0}"                   # ← 添加默认值
COUNTRY="${COUNTRY:-AM}"              # ← 添加默认值

# 獲取一個隨機端口
get_free_port() {
    echo $(( ( RANDOM % 20000 ) + 10000 ))
}

quicktunnel() {
    echo "--- 正在強制設定 DNS 為 1.1.1.1/1.0.0.1 ---"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 1.0.0.1" >> /etc/resolv.conf

    echo "--- 正在下載服務二進制文件 ---"

    local ARCH
    ARCH=$(uname -m)

    local ECH_URL=""
    local OPERA_URL=""
    local CLOUDFLARED_URL=""

    case "$ARCH" in
        x86_64 | x64 | amd64 )
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-amd64"
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-amd64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        i386 | i686 )
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-386"
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-386"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386"
            ;;
        armv8 | arm64 | aarch64 )
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-arm64"
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-arm64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        * )
            echo "當前架構 $ARCH 沒有适配。退出。"
            exit 1
            ;;
    esac

    curl -fL "$ECH_URL" -o ech-server-linux
    curl -fL "$OPERA_URL" -o opera-linux
    curl -fL "$CLOUDFLARED_URL" -o cloudflared-linux

    chmod +x cloudflared-linux ech-server-linux opera-linux

    local COUNTRY_UPPER="${COUNTRY^^}"

    echo "--- 啟動服務 ---"

    # 端口分配：
    # Caddy = WSPORT
    # ECH   = WSPORT + 1
    if [ -z "$WSPORT" ]; then
        WSPORT=$(get_free_port)
        echo "WSPORT 未設置，自動選取給 Caddy 的端口: $WSPORT"
    else
        echo "使用自定義 WSPORT 給 Caddy: $WSPORT"
    fi

    ECHPORT=$((WSPORT + 1))
    export WSPORT ECHPORT
    echo "ECH Server 將使用端口: $ECHPORT"

    # 1) Opera Proxy
    if [ "$OPERA" = "1" ]; then
        operaport=$(get_free_port)
        echo "啟動 Opera Proxy (port: $operaport, country: $COUNTRY_UPPER)..."
        nohup ./opera-linux \
            -country "$COUNTRY_UPPER" \
            -socks-mode \
            -bind-address "127.0.0.1:$operaport" \
            > /dev/null 2>&1 &
        OPERA_PID=$!
    fi

    # 2) ECH Server
    sleep 1

    ECH_ARGS=(./ech-server-linux -l "ws://0.0.0.0:$ECHPORT")

    if [ -n "$TOKEN" ]; then
        ECH_ARGS+=(-token "$TOKEN")
        echo "ECH Server 已設置 token（不在前台顯示）"
    else
        echo "ECH Server 未設置 token"
    fi

    if [ "$OPERA" = "1" ]; then
        ECH_ARGS+=(-f "socks5://127.0.0.1:$operaport")
    fi

    echo "啟動 ECH Server (port: $ECHPORT)..."
    nohup "${ECH_ARGS[@]}" > /dev/null 2>&1 &
    ECH_PID=$!

    # 3) Cloudflared -> ECHPORT
    metricsport=${ARGO_PORT:-$(get_free_port)}
    echo "啟動 Cloudflared Tunnel (metrics port: $metricsport)..."
    ./cloudflared-linux update > /dev/null 2>&1 || true

    # ===== 关键修复：创建日志文件用于调试 =====
    CLOUDFLARED_LOG="/tmp/cloudflared.log"
    
    ARGO_ARGS=("--protocol" "http2")
    if [ -n "$ARGO_AUTH" ]; then
        # 创建绝对路径的凭证文件
        ARGO_AUTH_FILE="/tmp/argo_auth.json"
        echo "$ARGO_AUTH" > "$ARGO_AUTH_FILE"
        chmod 600 "$ARGO_AUTH_FILE"
        ARGO_ARGS+=("--credentials-file" "$ARGO_AUTH_FILE")
        echo "✓ Argo 凭证文件已写入: $ARGO_AUTH_FILE"
    fi

    if [ -n "$ARGO_DOMAIN" ]; then
        ARGO_ARGS+=("--hostname" "$ARGO_DOMAIN")
        echo "✓ 使用固定隧道域名: $ARGO_DOMAIN"
    else
        echo "✓ 使用临时隧道"
    fi

    # ===== 启动 Cloudflared，保留日志用于调试 =====
    echo "正在启动 Cloudflared..."
    nohup ./cloudflared-linux \
        --edge-ip-version "$IPS" \
        tunnel --url "127.0.0.1:$ECHPORT" \
        --metrics "0.0.0.0:$metricsport" \
        "${ARGO_ARGS[@]}" \
        > "$CLOUDFLARED_LOG" 2>&1 &
    CF_PID=$!
    
    echo "Cloudflared PID: $CF_PID"
    sleep 3
    
    # 检查进程是否还在运行
    if ! kill -0 $CF_PID 2>/dev/null; then
        echo "❌ Cloudflared 启动失败！错误信息："
        cat "$CLOUDFLARED_LOG"
        echo ""
        echo "请检查："
        echo "1. ARGO_AUTH 凭证是否正确"
        echo "2. ARGO_DOMAIN 是否有效（固定隧道模式）"
        echo "3. 网络连接是否正常"
        exit 1
    fi
    
    echo "✓ Cloudflared 进程已启动"

    # 4) 获取 Argo 域名
    if [ -z "$ARGO_DOMAIN" ]; then
        echo "--- 正在获取临时隧道域名 ---"
        DOMAIN=""
        for attempt in {1..60}; do
            echo "尝试 $attempt/60..."
            RESP=$(curl -s "http://127.0.0.1:$metricsport/metrics" 2>/dev/null || true)

            if echo "$RESP" | grep -q 'userHostname='; then
                DOMAIN=$(echo "$RESP" | grep 'userHostname="' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/')
                if [ -n "$DOMAIN" ]; then
                    echo "--- ECH + Cloudflared 啟動成功 ---"
                    if [ -z "$TOKEN" ]; then
                        echo "未設置 token, 連接為: $DOMAIN:443"
                    else
                        echo "已設置 token, 連接為: $DOMAIN:443 （token 不顯示）"
                    fi
                    break
                fi
            fi
            sleep 1
        done
        
        if [ -z "$DOMAIN" ]; then
            echo "❌ 无法获取临时隧道域名"
            echo "Cloudflared 日志:"
            tail -20 "$CLOUDFLARED_LOG"
            exit 1
        fi
    else
        DOMAIN="$ARGO_DOMAIN"
        sleep 2
        echo "--- 使用固定 Argo 域名: $DOMAIN:443 ---"
        
        # 验证隧道连接状态
        if RESP=$(curl -s "http://127.0.0.1:$metricsport/metrics" 2>/dev/null); then
            if echo "$RESP" | grep -q 'userHostname='; then
                echo "✓ 隧道已成功连接"
            else
                echo "⚠ 隧道状态未知，请检查 metrics: http://127.0.0.1:$metricsport/metrics"
            fi
        fi
    fi
}

# ---------------- main ----------------

MODE="${1:-1}"

if [ "$MODE" = "1" ]; then
    # Opera 参数检查
    if [ "$OPERA" = "1" ]; then
        echo "已啟用 Opera 前置代理。"
        COUNTRY=${COUNTRY:-AM}
        COUNTRY=${COUNTRY^^}
        if [ "$COUNTRY" != "AM" ] && [ "$COUNTRY" != "AS" ] && [ "$COUNTRY" != "EU" ]; then
            echo "錯誤：請設置正確的 OPERA_COUNTRY (AM/AS/EU)。目前值: $COUNTRY"
            exit 1
        fi
    elif [ "$OPERA" != "0" ]; then
        echo "錯誤：OPERA 變數只能是 0 或 1。目前值: $OPERA"
        exit 1
    fi

    # IPS 参数检查
    if [ "$IPS" != "4" ] && [ "$IPS" != "6" ]; then
        echo "錯誤：IPS 變數只能是 4 或 6。目前值: $IPS"
        exit 1
    fi

    quicktunnel
else
    echo "使用非預期模式啟動。"
    exit 1
fi

echo "--- 啟動 Caddy 前台服務（port: $WSPORT）---"
# 最后用 exec 让 caddy 占据 PID1，容器不会退出
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
