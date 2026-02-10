FROM alpine:3.21

RUN apk add --no-cache curl jq

COPY alert.sh /alert.sh
COPY daily-report.sh /daily-report.sh
RUN chmod +x /alert.sh /daily-report.sh

ENTRYPOINT ["sh", "/alert.sh"]
