FROM jasonish/suricata:latest
RUN apt-get update && apt-get install -y --no-install-recommends iptables && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY entrypoint-ips.sh /entrypoint-ips.sh
RUN chmod +x /entrypoint-ips.sh
ENTRYPOINT ["/entrypoint-ips.sh"]
