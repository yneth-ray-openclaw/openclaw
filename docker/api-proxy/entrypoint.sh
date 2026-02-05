#!/bin/sh
envsubst '${ANTHROPIC_API_KEY} ${TELEGRAM_BOT_TOKEN}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
exec "$@"
