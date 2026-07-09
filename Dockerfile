FROM python:3.11-slim

WORKDIR /app

# Системные зависимости
RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Python зависимости
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Копируем код
COPY app.py .
COPY xray_config.json .
COPY start.sh .
RUN chmod +x start.sh

EXPOSE 5000

CMD ["bash", "start.sh"]
