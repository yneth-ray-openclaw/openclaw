FROM jasonish/suricata:7.0 AS builder

# Create drop.conf for converting critical threat categories from alert to drop
RUN printf '%s\n' \
    're:classtype:trojan-activity' \
    're:classtype:command-and-control' \
    're:classtype:exploit-kit' \
    're:classtype:web-application-attack' \
    're:classtype:attempted-admin' \
    're:classtype:shellcode-detect' \
    're:classtype:successful-admin' \
    're:classtype:successful-recon-limited' \
    > /tmp/drop.conf

# Enable additional threat feeds
RUN suricata-update enable-source abuse.ch/sslbl-blacklist && \
    suricata-update enable-source abuse.ch/sslbl-ja3

# Download and apply rules with drop policy
RUN suricata-update --no-reload --drop-conf /tmp/drop.conf

# Patch suricata.yaml for IPS mode
RUN cp /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.bak && \
    sed 's|HOME_NET:.*".*"|HOME_NET: "[172.16.0.0/12]"|' /etc/suricata/suricata.yaml > /tmp/suricata.yaml && mv /tmp/suricata.yaml /etc/suricata/suricata.yaml && \
    sed 's|default-log-dir:.*|default-log-dir: /var/log/suricata/|' /etc/suricata/suricata.yaml > /tmp/suricata.yaml && mv /tmp/suricata.yaml /etc/suricata/suricata.yaml && \
    sed 's/# *nfq:/nfq:/' /etc/suricata/suricata.yaml > /tmp/suricata.yaml && mv /tmp/suricata.yaml /etc/suricata/suricata.yaml && \
    sed '/nfq:/,/fail-open:/ s/fail-open: .*/fail-open: no/' /etc/suricata/suricata.yaml > /tmp/suricata.yaml && mv /tmp/suricata.yaml /etc/suricata/suricata.yaml && \
    sed '/^stream:/,/^[^ ]/ s/inline: .*/inline: auto/' /etc/suricata/suricata.yaml > /tmp/suricata.yaml && mv /tmp/suricata.yaml /etc/suricata/suricata.yaml && \
    sed '/- dns:/,/^[[:space:]]*-/ s/enabled: no/enabled: yes/' /etc/suricata/suricata.yaml > /tmp/suricata.yaml && mv /tmp/suricata.yaml /etc/suricata/suricata.yaml && \
    sed '/- http:/,/^[[:space:]]*-/ s/enabled: no/enabled: yes/' /etc/suricata/suricata.yaml > /tmp/suricata.yaml && mv /tmp/suricata.yaml /etc/suricata/suricata.yaml && \
    sed '/- tls:/,/^[[:space:]]*-/ s/enabled: no/enabled: yes/' /etc/suricata/suricata.yaml > /tmp/suricata.yaml && mv /tmp/suricata.yaml /etc/suricata/suricata.yaml

FROM jasonish/suricata:7.0

RUN dnf install -y --setopt=install_weak_deps=False iptables && dnf clean all

COPY --from=builder /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml
COPY --from=builder /var/lib/suricata/rules/ /var/lib/suricata/rules/
COPY --from=builder /tmp/drop.conf /var/lib/suricata/drop.conf
COPY entrypoint-ips.sh /entrypoint-ips.sh
RUN chmod +x /entrypoint-ips.sh
ENTRYPOINT ["/entrypoint-ips.sh"]
