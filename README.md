# Where is granny?

Mobil nettapp (PWA) for jaktleken i Grimstad: 10 grannies, en Rømling og 10 letelag i 2,5 timer.

- **Design:** [Figma – UX, design system og profil](https://www.figma.com/design/KU5kUCDxFU0WzZ0Wy6OBZj). Skjermkodene i koden (G1, L1, F2b, S1 …) viser til skjermene der.
- **Stack:** React + Vite + TypeScript, Tailwind v4 med tokens fra Figma, MapLibre + Protomaps, Supabase (Postgres/PostGIS, Auth, Storage, Edge Functions), hostes som Cloudflare Worker med statiske filer.
- **Posisjon:** grannyene deler Telegram live-posisjon med en bot. Det virker med låst skjerm. Appens egen GPS brukes bare mens appen er åpen.

## Kom i gang lokalt

Krever Node 22+, pnpm og Docker.

```bash
pnpm install
pnpm db:start          # Supabase lokalt på port 544xx, med testdata
cp .env.example .env.local   # fyll inn PUBLISHABLE_KEY fra db:start
pnpm dev               # http://127.0.0.1:5173
```

Testkoder (fra `supabase/seed.sql`): `TEST-ADMIN`, `TEST-BLA`, `TEST-ROD`, `TEST-GRONN`, `TEST-ASTRID`, `TEST-GERD`, `TEST-SOLVEIG`, `TEST-ROMLING`.

Telegram lokalt (uten ekte bot):

```bash
printf 'TELEGRAM_BOT_TOKEN=\nTELEGRAM_WEBHOOK_SECRET=local-test-secret\n' > supabase/functions/.env
pnpm functions:serve
curl -X POST http://127.0.0.1:54421/functions/v1/telegram-webhook \
  -H 'x-telegram-bot-api-secret-token: local-test-secret' \
  -d '{"update_id":1,"message":{"message_id":1,"date":1,"chat":{"id":777,"type":"private"},"from":{"id":777},"text":"/start test-astrid"}}'
```

## Tester

```bash
pnpm test       # spillklokke og ping (Vitest)
pnpm db:test    # tilgang, ping-logikk, blind, pause (pgTAP)
pnpm build      # typecheck + produksjonsbygg
```

## Arkitektur

**Spilltid.** Alt regnes i sekunder siden start, minus pauser (`game_seconds()`). Blind, taxi-sperre og nedkjøling lagres i spilltid, så pause fryser dem. Klienten teller lokalt mellom hentingene og spør serveren hvert 20. sekund.

**Ping.** Ingen jobb kjører ved ping. `team_map()` finner siste ping-tidspunkt og returnerer hver grannys siste posisjon *før* det. Grannies som er sladret på eller har vært utenfor spillområdet i over 60 sek, vises med nåværende posisjon.

**Hemmeligheter.** Klienter kan ikke skrive til tabellene, og lag kan ikke lese posisjoner. Rømlingens navn, postkortsoner, sladrehank og fotograf er bare synlige for spilleder eller via RPC-er som filtrerer. Repoet er offentlig, så ekte steder og Rømlingens navn legges bare inn i databasen.

**Innlogging.** Anonym Supabase-innlogging og en kode per lag, granny og spilleder. Flere telefoner kan dele en lagkode.

## Beslutninger (10. nov 2026)

| Spørsmål | Beslutning |
| --- | --- |
| Posisjon i bakgrunnen | Telegram live-posisjon via bot, ikke native app |
| Letelag | Alle på laget logger inn med samme lagkode |
| Dobbel fangst | Grannyen velger hvilket lag som tok henne |
| Telegram slutter å sende | Påminnelse etter 60 sek, spilleders kø etter 3 min, ping bruker siste kjente |
| Pause | Klokka og alle tidsfrister fryser |
| Utenfor området | Varsel, deretter live for lagene etter 60 sek. Ingen poengtrekk |
| Bingo-poeng | Stigende: 2, 3, 4, så 5p |
| Honnørrabatt | 75 min regnes fra 0:00 |
| Rømlingen og taxi | Samme regel som grannyene |
| Sletting | Posisjoner og bilder slettes etter 30 dager |

## Status

Ferdig: skjema og RLS for hele spillet, innlogging med kode, spillklokke med pause, Telegram-webhook, granny-kart (G1), Telegram-kobling (F2b), lagkart med ping og blind (L1/L7), spilleders live-oversikt (S1).

Ikke laget ennå: fangst og bekreftelse, oppgaver (Sladrehanken, Fotoalbumet, Bingo, Taxi, Nabovakt, Rømlingen, Postkort), kamera og bildegodkjenning, varsler (Web Push), Telegram-påminnelser, oppsett-skjerm for spilleder (S2), oppsummering, automatisk sletting.

## Produksjon – sjekkliste

Steg for steg for første deploy og felttesten: [docs/DEPLOY.md](docs/DEPLOY.md).


- Opprett Supabase-prosjekt i EU (Stockholm), `supabase link`, `supabase db push`.
- Slå på anonym innlogging og **øk grensen for anonyme innlogginger per IP** (standard 30/time). 111 spillere på samme Wi-Fi eller mobilnett vil ellers bli stoppet.
- Lag boten hos @BotFather, sett `supabase secrets set TELEGRAM_BOT_TOKEN=… TELEGRAM_WEBHOOK_SECRET=…`, deploy funksjonen og kjør `scripts/telegram-set-webhook.sh`.
- Lag et Grimstad-utsnitt: `pmtiles extract https://build.protomaps.com/<dato>.pmtiles grimstad.pmtiles --bbox=8.55,58.32,8.63,58.36`, legg det i R2 og sett `VITE_PMTILES_URL`. OSM-flisene brukes bare i utvikling.
- Fonter: Young Serif og Sofia Sans har åpen lisens og er med i bygget. Integral CF (klokke, etiketter, logo-undertittel) er kommersiell og ligger ikke i repoet. Se `docs/brand-fonts.example.css` og `VITE_BRAND_FONTS_URL`. Sjekk at klokka ikke hopper med Integral CF, siden fonten kanskje ikke har tall med fast bredde.
- Supabase Pro i spillmåneden (gratisnivået har 200 samtidige tilkoblinger).
- Felttest i Grimstad før spilldagen: hvor ofte Telegram sender posisjon, GPS-avvik i sentrum, batteri over 2,5 timer.
