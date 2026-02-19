FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY filter.py .

RUN apt-get update && apt-get install -y cron \
    && rm -rf /var/lib/apt/lists/* \
    && echo "0 8 * * * python /app/filter.py >> /app/data/filter.log 2>&1" > /etc/cron.d/news-filter \
    && chmod 0644 /etc/cron.d/news-filter

CMD ["cron", "-f"]
