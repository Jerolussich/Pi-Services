FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY export.py .

# Install cron first, then set up the job
RUN apt-get update && apt-get install -y cron \
    && rm -rf /var/lib/apt/lists/* \
    && echo "0 6 1 * * python /app/export.py >> /app/exports/export.log 2>&1" > /etc/cron.d/fitbit-exporter \
    && chmod 0644 /etc/cron.d/fitbit-exporter

CMD ["cron", "-f"]
