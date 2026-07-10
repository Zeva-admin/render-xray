import os
import uuid
import json
import base64
import subprocess
import threading
import time
import logging
import socket

from flask import Flask, Response, request, send_file

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# ─── Конфигурация ────────────────────────────────────────────────────────────

def get_uuid() -> str:
    """Берёт UUID из ENV или генерирует и сохраняет в файл при первом запуске."""
    env_uuid = os.environ.get("UUID", "").strip()
    if env_uuid:
        return env_uuid
    cache_path = "/tmp/.cocut_uuid"
    if os.path.exists(cache_path):
        with open(cache_path) as f:
            return f.read().strip()
    new_uuid = str(uuid.uuid4())
    with open(cache_path, "w") as f:
        f.write(new_uuid)
    logger.info(f"[cocut] Сгенерирован новый UUID: {new_uuid}")
    return new_uuid


def get_domain() -> str:
    # ИСПРАВЛЕНО: поддержка Railway, Render и ручной переменной DOMAIN
    return (
        os.environ.get("DOMAIN")                  # ручная переменная (приоритет)
        or os.environ.get("RAILWAY_PUBLIC_DOMAIN") # Railway (автоматически)
        or os.environ.get("RENDER_EXTERNAL_HOSTNAME") # Render.com
        or "localhost"
    )


def get_port() -> int:
    return int(os.environ.get("PORT", 5000))


XRAY_PORT = 8080
XRAY_PATH = "/ws"
USER_UUID = get_uuid()

# ─── Запуск xray-core ─────────────────────────────────────────────────────────

def patch_xray_config():
    """Вставляет UUID в xray_config.json перед запуском."""
    config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "xray_config.json")
    with open(config_path) as f:
        config = json.load(f)

    config["inbounds"][0]["settings"]["clients"][0]["id"] = USER_UUID
    patched_path = "/tmp/xray_config_patched.json"
    with open(patched_path, "w") as f:
        json.dump(config, f, indent=2)
    return patched_path


def xray_runner():
    """Запускает xray-core в отдельном потоке и перезапускает при падении."""
    # Ищем xray бинарник: сначала рядом со скриптом, потом в /tmp
    base_dir = os.path.dirname(os.path.abspath(__file__))
    xray_bin = os.path.join(base_dir, "xray")
    if not os.path.exists(xray_bin):
        xray_bin = "/tmp/xray"

    config_path = patch_xray_config()

    while True:
        logger.info("[xray] Запуск xray-core...")
        try:
            proc = subprocess.Popen(
                [xray_bin, "run", "-config", config_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            for line in proc.stdout:
                logger.info(f"[xray] {line.decode().rstrip()}")
            proc.wait()
            logger.warning(f"[xray] Процесс завершился с кодом {proc.returncode}, перезапуск через 5с...")
        except FileNotFoundError:
            logger.error(f"[xray] Бинарник не найден: {xray_bin}. Повтор через 10с...")
            time.sleep(10)
            continue
        except Exception as e:
            logger.error(f"[xray] Ошибка: {e}. Повтор через 5с...")
        time.sleep(5)


def start_xray():
    t = threading.Thread(target=xray_runner, daemon=True)
    t.start()
    # Даём xray время подняться
    time.sleep(3)
    logger.info(f"[cocut] xray запущен, UUID={USER_UUID}, домен={get_domain()}")

# ─── Подписка ─────────────────────────────────────────────────────────────────

def build_vless_link(domain: str) -> str:
    params = (
        f"encryption=none"
        f"&security=tls"
        f"&sni={domain}"
        f"&type=ws"
        f"&host={domain}"
        f"&path=%2Fws"
    )
    return f"vless://{USER_UUID}@{domain}:443?{params}#Cocut"


@app.route("/sub", methods=["GET"])
def subscription():
    domain = get_domain()
    link = build_vless_link(domain)
    logger.info(f"[sub] Отдаём ссылку для домена: {domain}")
    encoded = base64.b64encode(link.encode()).decode()
    return Response(
        encoded,
        status=200,
        headers={
            "Content-Type": "text/plain; charset=utf-8",
            "profile-title": base64.b64encode("Cocut".encode()).decode(),
            "profile-update-interval": "24",
            "subscription-userinfo": "upload=0; download=0; total=107374182400; expire=0",
            "Content-Disposition": "inline; filename=cocut.txt",
        },
    )

# ─── WebSocket прокси /ws → xray :8080 ───────────────────────────────────────

def get_raw_socket(environ):
    """
    Достаём raw TCP-сокет из WSGI environ.
    Работает с gevent worker (gunicorn + gevent).
    """
    # gevent/eventlet worker
    sock = environ.get("gunicorn.socket")
    if sock:
        return sock

    # werkzeug dev server
    sock = environ.get("werkzeug.socket")
    if sock:
        return sock

    # Попытка через wsgi.input (gevent обёртка)
    wsgi_input = environ.get("wsgi.input")
    if wsgi_input is None:
        return None

    # gevent: wsgi.input -> raw -> _sock
    for attr in ("raw", "_sock", "raw_stream"):
        inner = getattr(wsgi_input, attr, None)
        if inner is not None:
            if hasattr(inner, "recv"):
                return inner
            sock = getattr(inner, "_sock", None)
            if sock:
                return sock

    return None


@app.route("/ws", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
@app.route("/ws/<path:subpath>", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
def ws_proxy(subpath=""):
    # Обычные HTTP запросы (health check и т.п.)
    if request.method != "GET" or request.headers.get("Upgrade", "").lower() != "websocket":
        return Response("OK", 200)

    environ = request.environ
    sock = get_raw_socket(environ)

    if sock is None:
        logger.error("[ws] Не удалось получить raw socket. Убедись что gunicorn запущен с gevent worker (-k gevent)")
        return Response("WebSocket proxy unavailable: no raw socket. Use gevent worker.", 503)

    # Подключаемся к xray
    xray_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        xray_sock.connect(("127.0.0.1", XRAY_PORT))
    except ConnectionRefusedError:
        logger.error("[ws] xray не запущен или ещё не поднялся")
        return Response("xray not ready", 503)

    # Пробрасываем HTTP Upgrade к xray
    ws_key = request.headers.get("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
    ws_ver = request.headers.get("Sec-WebSocket-Version", "13")
    raw_request = (
        f"GET {XRAY_PATH} HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{XRAY_PORT}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {ws_key}\r\n"
        f"Sec-WebSocket-Version: {ws_ver}\r\n"
        f"\r\n"
    )
    xray_sock.sendall(raw_request.encode())

    def forward(src, dst, label):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except Exception as e:
            logger.debug(f"[proxy:{label}] {e}")
        finally:
            for s in (src, dst):
                try:
                    s.close()
                except Exception:
                    pass

    t1 = threading.Thread(target=forward, args=(sock, xray_sock, "client→xray"), daemon=True)
    t2 = threading.Thread(target=forward, args=(xray_sock, sock, "xray→client"), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()

    return Response("", 200)

# ─── Info endpoint ─────────────────────────────────────────────────────────────

@app.route("/info", methods=["GET"])
def info():
    """Отладочный эндпоинт — показывает текущий UUID и домен."""
    domain = get_domain()
    return Response(
        json.dumps({
            "uuid": USER_UUID,
            "domain": domain,
            "vless": build_vless_link(domain),
        }, ensure_ascii=False),
        200,
        content_type="application/json; charset=utf-8",
    )

# ─── Health check ─────────────────────────────────────────────────────────────

@app.route("/", methods=["GET"])
def index():
    # Отдаём красивый личный кабинет
    html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
    if os.path.exists(html_path):
        return send_file(html_path, mimetype="text/html")
    # Fallback если файл не найден
    return Response(
        json.dumps({"status": "ok", "service": "Cocut"}),
        200,
        content_type="application/json",
    )


@app.route("/health", methods=["GET"])
def health():
    return Response("OK", 200)

# ─── Точка входа ──────────────────────────────────────────────────────────────

# start_xray вызывается из start.sh ДО gunicorn,
# но на случай запуска через `python app.py` — тоже запускаем
if __name__ == "__main__":
    start_xray()
    port = get_port()
    logger.info(f"[cocut] Flask dev-сервер на порту {port}")
    app.run(host="0.0.0.0", port=port)
