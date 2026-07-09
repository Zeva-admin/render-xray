#!/usr/bin/env bash
set -e

XRAY_BIN="./xray"
XRAY_VERSION="1.8.24"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"

# ─── Скачиваем xray если нет ─────────────────────────────────────────────────
if [ ! -f "$XRAY_BIN" ]; then
    echo "[start.sh] xray не найден, скачиваем v${XRAY_VERSION}..."

    # Проверяем наличие инструментов
    if command -v curl &>/dev/null; then
        curl -fsSL -o /tmp/xray.zip "$XRAY_URL"
    elif command -v wget &>/dev/null; then
        wget -q -O /tmp/xray.zip "$XRAY_URL"
    else
        echo "[start.sh] ОШИБКА: нет ни curl ни wget" >&2
        exit 1
    fi

    echo "[start.sh] Распаковываем архив..."
    if command -v unzip &>/dev/null; then
        unzip -o /tmp/xray.zip xray -d . 2>/dev/null || unzip -o /tmp/xray.zip -d /tmp/xray_extract
        if [ ! -f "$XRAY_BIN" ]; then
            cp /tmp/xray_extract/xray "$XRAY_BIN" 2>/dev/null || true
        fi
    else
        echo "[start.sh] ОШИБКА: unzip не найден, устанавливаем..." >&2
        apt-get install -y unzip -qq 2>/dev/null || apk add unzip -q 2>/dev/null || true
        unzip -o /tmp/xray.zip xray -d . 2>/dev/null || true
    fi

    rm -f /tmp/xray.zip

    if [ ! -f "$XRAY_BIN" ]; then
        echo "[start.sh] ОШИБКА: xray бинарник не удалось получить" >&2
        exit 1
    fi

    echo "[start.sh] xray успешно скачан"
else
    echo "[start.sh] xray уже присутствует, пропускаем загрузку"
fi

# ─── Права на исполнение ─────────────────────────────────────────────────────
chmod +x "$XRAY_BIN"
echo "[start.sh] xray: $(./xray version 2>&1 | head -1)"

# ─── UUID ────────────────────────────────────────────────────────────────────
if [ -z "$UUID" ]; then
    echo "[start.sh] ВНИМАНИЕ: ENV UUID не задан, будет сгенерирован случайный"
fi

# ─── Запуск gunicorn ─────────────────────────────────────────────────────────
PORT="${PORT:-5000}"
WORKERS="${GUNICORN_WORKERS:-1}"

echo "[start.sh] Запускаем gunicorn на порту ${PORT}..."
exec gunicorn app:app \
    --bind "0.0.0.0:${PORT}" \
    --workers "${WORKERS}" \
    --worker-class sync \
    --timeout 120 \
    --keep-alive 75 \
    --log-level info \
    --access-logfile - \
    --error-logfile -