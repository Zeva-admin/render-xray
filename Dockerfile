FROM python:3.11-slim

WORKDIR /app

# Системные зависимости
# libev-dev нужен для gevent (WebSocket worker)
RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    libev-dev \
    && rm -rf /var/lib/apt/lists/*

# Python зависимости
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Копируем код
COPY app.py .
COPY xray_config.json .
COPY start.sh .
COPY index.html .
COPY admin65858137.html .
RUN chmod +x start.sh

EXPOSE 5000

CMD ["bash", "start.sh"]
