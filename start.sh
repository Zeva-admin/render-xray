#!/usr/bin/env bash
set -e

XRAY_BIN="./xray"
XRAY_VERSION="1.8.24"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"

# ─── Скачиваем xray если нет ─────────────────────────────────────────────────
if [ ! -f "$XRAY_BIN" ]; then
    echo "[start.sh] xray не найден, скачиваем v${XRAY_VERSION}..."

    if command -v curl &>/dev/null; then
        curl -fsSL -o /tmp/xray.zip "$XRAY_URL"
    elif command -v wget &>/dev/null; then
        wget -q -O /tmp/xray.zip "$XRAY_URL"
    else
        echo "[start.sh] ОШИБКА: нет ни curl ни wget" >&2
        exit 1
    fi

    echo "[start.sh] Распаковываем архив..."
    unzip -o /tmp/xray.zip xray -d . 2>/dev/null || {
        mkdir -p /tmp/xray_extract
        unzip -o /tmp/xray.zip -d /tmp/xray_extract
        cp /tmp/xray_extract/xray "$XRAY_BIN" 2>/dev/null || true
    }

    rm -f /tmp/xray.zip
    [ -f "$XRAY_BIN" ] || { echo "[start.sh] ОШИБКА: xray не удалось получить" >&2; exit 1; }
    echo "[start.sh] xray успешно скачан"
else
    echo "[start.sh] xray уже есть, пропускаем загрузку"
fi

chmod +x "$XRAY_BIN"
echo "[start.sh] xray: $(./xray version 2>&1 | head -1)"

# ─── UUID ────────────────────────────────────────────────────────────────────
if [ -z "$UUID" ]; then
    echo "[start.sh] ВНИМАНИЕ: ENV UUID не задан, будет сгенерирован случайный"
fi

# ─── Домен ───────────────────────────────────────────────────────────────────
# Railway автоматически предоставляет RAILWAY_PUBLIC_DOMAIN
# Можно также задать вручную переменную DOMAIN
if [ -n "$DOMAIN" ]; then
    echo "[start.sh] Домен из переменной DOMAIN: $DOMAIN"
elif [ -n "$RAILWAY_PUBLIC_DOMAIN" ]; then
    echo "[start.sh] Домен из Railway: $RAILWAY_PUBLIC_DOMAIN"
else
    echo "[start.sh] ВНИМАНИЕ: домен не определён автоматически. Задай переменную DOMAIN."
fi

# ─── Запуск gunicorn с gevent worker ─────────────────────────────────────────
# ВАЖНО: gevent worker нужен для WebSocket TCP hijack!
PORT="${PORT:-5000}"
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
