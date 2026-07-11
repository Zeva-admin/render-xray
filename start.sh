#!/usr/bin/env bash
set -e

XRAY_BIN="./xray"
XRAY_VERSION="1.8.24"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"
NGROK_VERSION="3.22.1"
NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz"

# ─── Скачиваем xray ──────────────────────────────────────────────────────────
if [ ! -f "$XRAY_BIN" ]; then
    echo "[start.sh] xray не найден, скачиваем v${XRAY_VERSION}..."
    curl -fsSL -o /tmp/xray.zip "$XRAY_URL"
    echo "[start.sh] Распаковываем xray..."
    unzip -o /tmp/xray.zip xray -d . 2>/dev/null || {
        mkdir -p /tmp/xray_extract
        unzip -o /tmp/xray.zip -d /tmp/xray_extract
        cp /tmp/xray_extract/xray "$XRAY_BIN" 2>/dev/null || true
    }
    rm -f /tmp/xray.zip
    [ -f "$XRAY_BIN" ] || { echo "[start.sh] ОШИБКА: xray не найден" >&2; exit 1; }
    echo "[start.sh] xray успешно скачан"
fi
chmod +x "$XRAY_BIN"
echo "[start.sh] xray: $(./xray version 2>&1 | head -1)"

# ─── Скачиваем ngrok ──────────────────────────────────────────────────────────
if [ ! -f "/tmp/ngrok" ]; then
    echo "[start.sh] Скачиваем ngrok..."
    curl -fsSL -o /tmp/ngrok.tgz "$NGROK_URL"
    tar -xzf /tmp/ngrok.tgz -C /tmp/
    rm -f /tmp/ngrok.tgz
    chmod +x /tmp/ngrok
    echo "[start.sh] ngrok скачан"
fi

# ─── UUID ────────────────────────────────────────────────────────────────────
if [ -z "$UUID" ]; then
    echo "[start.sh] ВНИМАНИЕ: ENV UUID не задан, будет сгенерирован случайный"
fi

# ─── Домен ───────────────────────────────────────────────────────────────────
# Если есть NGROK_DOMAIN — используем его как основной домен
if [ -n "$NGROK_DOMAIN" ]; then
    export DOMAIN="$NGROK_DOMAIN"
    echo "[start.sh] Домен через ngrok: $DOMAIN"
elif [ -n "$DOMAIN" ]; then
    echo "[start.sh] Домен из переменной DOMAIN: $DOMAIN"
elif [ -n "$RAILWAY_PUBLIC_DOMAIN" ]; then
    echo "[start.sh] Домен из Railway: $RAILWAY_PUBLIC_DOMAIN"
else
    echo "[start.sh] ВНИМАНИЕ: домен не определён"
fi

# ─── Запускаем ngrok туннель ─────────────────────────────────────────────────
if [ -n "$NGROK_AUTHTOKEN" ] && [ -n "$NGROK_DOMAIN" ]; then
    echo "[start.sh] Запускаем ngrok туннель на домене $NGROK_DOMAIN..."
    /tmp/ngrok config add-authtoken "$NGROK_AUTHTOKEN" 2>/dev/null || true
    # Туннель: ngrok проксирует HTTPS на наш gunicorn порт
    PORT_FOR_NGROK="${PORT:-3000}"
    /tmp/ngrok http \
        --domain="$NGROK_DOMAIN" \
        --log=stdout \
        --log-level=warn \
        "$PORT_FOR_NGROK" &
    NGROK_PID=$!
    echo "[start.sh] ngrok PID=$NGROK_PID запущен"
    sleep 3
else
    echo "[start.sh] ВНИМАНИЕ: NGROK_AUTHTOKEN или NGROK_DOMAIN не заданы, ngrok не запускается"
fi

# ─── Запуск gunicorn ─────────────────────────────────────────────────────────
PORT="${PORT:-3000}"
WORKERS="${GUNICORN_WORKERS:-1}"

echo "[start.sh] Запускаем gunicorn (gevent) на порту ${PORT}..."
exec gunicorn app:app \
    --bind "0.0.0.0:${PORT}" \
    --workers "${WORKERS}" \
    --worker-class gevent \
    --worker-connections 1000 \
    --timeout 120 \
    --keep-alive 75 \
    --log-level info \
    --access-logfile - \
    --error-logfile -
