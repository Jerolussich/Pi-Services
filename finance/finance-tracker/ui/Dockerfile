FROM python:3.13-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends poppler-utils \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
COPY parsers/ parsers/
COPY templates/ templates/
CMD ["gunicorn", "--bind", "0.0.0.0:8085", "--workers", "2", "app:app"]
