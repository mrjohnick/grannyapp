#!/usr/bin/env bash
# Kobler GrannyBot til webhooken i Supabase.
#
# Bruk:
#   TELEGRAM_BOT_TOKEN=... TELEGRAM_WEBHOOK_SECRET=... \
#   ./scripts/telegram-set-webhook.sh https://<prosjekt>.supabase.co/functions/v1/telegram-webhook
#
# Samme TELEGRAM_WEBHOOK_SECRET må settes i Supabase:
#   supabase secrets set TELEGRAM_BOT_TOKEN=... TELEGRAM_WEBHOOK_SECRET=...
set -euo pipefail

URL="${1:?Oppgi webhook-URL}"
: "${TELEGRAM_BOT_TOKEN:?Mangler TELEGRAM_BOT_TOKEN}"
: "${TELEGRAM_WEBHOOK_SECRET:?Mangler TELEGRAM_WEBHOOK_SECRET}"

curl -sS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
  -H 'content-type: application/json' \
  -d "{\"url\":\"${URL}\",\"secret_token\":\"${TELEGRAM_WEBHOOK_SECRET}\",\"allowed_updates\":[\"message\",\"edited_message\"],\"drop_pending_updates\":true}"
echo
curl -sS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo"
echo
