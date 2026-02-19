FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY fetch.py .

RUN apt-get update && apt-get install -y cron \
    && rm -rf /var/lib/apt/lists/* \
    && echo "0 * * * * python /app/fetch.py >> /app/data/tracker.log 2>&1" > /etc/cron.d/itau-tracker \
    && chmod 0644 /etc/cron.d/itau-tracker

CMD ["cron", "-f"]
