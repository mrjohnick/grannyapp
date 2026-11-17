#!/usr/bin/env bash
# Setter opp Web Push i produksjon. Kjøres én gang fra prosjektmappa.
#
#   ./scripts/push-setup.sh https://<din-app-adresse>
#
# Lager VAPID-nøkler og lagrer dem som hemmeligheter i Supabase. Den private
# nøkkelen skrives aldri ut. Den offentlige nøkkelen skrives ut, fordi den skal
# inn som byggvariabel i Cloudflare (VITE_VAPID_PUBLIC_KEY).
#
# Kjører du skriptet på nytt, lages nye nøkler. Da må alle slå på varsler igjen.
set -euo pipefail

APP_URL="${1:?Oppgi app-adressen, f.eks. https://grannyapp.example.workers.dev}"

KEYS="$(npx -y web-push@3.6.7 generate-vapid-keys --json)"
PUBLIC="$(node -e 'console.log(JSON.parse(process.argv[1]).publicKey)' "$KEYS")"
PRIVATE="$(node -e 'console.log(JSON.parse(process.argv[1]).privateKey)' "$KEYS")"

npx supabase secrets set \
  "VAPID_PUBLIC_KEY=${PUBLIC}" \
  "VAPID_PRIVATE_KEY=${PRIVATE}" \
  "VAPID_SUBJECT=${APP_URL}" >/dev/null
unset PRIVATE KEYS

echo "VAPID-nøklene er lagret i Supabase."
echo
echo "Legg inn denne som byggvariabel i Cloudflare og bygg på nytt:"
echo "  VITE_VAPID_PUBLIC_KEY=${PUBLIC}"
