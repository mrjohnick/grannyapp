# Deploy og felttest

Målet med første deploy er å måle Telegram live-posisjon i Grimstad før vi bygger resten av spillet.
Rekkefølgen under er viktig: boten og Supabase først, så nettappen, så felttesten.

Steg merket **(du)** krever dine kontoer. Lim aldri inn bot-token eller hemmelige nøkler i en chat eller i repoet.

---

## 1. Telegram-bot (du)

1. Åpne [@BotFather](https://t.me/BotFather) i Telegram og send `/newbot`.
2. Navn: `Where is granny?`. Brukernavn: f.eks. `WhereIsGrannyBot` (må slutte på `bot`).
3. Lagre tokenet i passordbehandleren din.
4. Send `/setjoingroups`, velg boten, velg **Disable**. Da kan ingen legge boten i en lag-gruppe og dele posisjon der.
5. Valgfritt: `/setuserpic` med app-ikonet og `/setdescription` med «Del live-posisjonen din her under jakten.»

## 2. Supabase (du + terminal)

**I dashbordet**

1. Nytt prosjekt, region **North EU (Stockholm)**. Gratisnivå holder for felttesten.
2. Authentication → Sign In / Providers → slå på **Anonymous sign-ins**.
3. Authentication → Rate Limits → «Anonymous sign-ins per hour»: sett til **300**. Standard er 30 per IP, som stopper spillere på samme nett.
4. Authentication → URL Configuration → Site URL: adressen fra Cloudflare (steg 3). Kan settes etterpå.
5. Project Settings → API Keys: noter **Project URL** og **Publishable key**.

**I terminalen** (fra `grannyapp/`)

```bash
pnpm exec supabase login
```

```bash
pnpm exec supabase link --project-ref <prosjekt-ref>
```

```bash
pnpm deploy:db
```

`deploy:db` kjører migrasjonene mot det koblede prosjektet (`--remote`; CLI v3 bruker ellers lokal database). Testdataene i `seed.sql` blir **ikke** med.

Lag en tilfeldig webhook-hemmelighet og lagre den sammen med bot-tokenet:

```bash
export TELEGRAM_WEBHOOK_SECRET=$(openssl rand -hex 32)
```

```bash
read -s TELEGRAM_BOT_TOKEN && export TELEGRAM_BOT_TOKEN
```

```bash
pnpm exec supabase secrets set TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" TELEGRAM_WEBHOOK_SECRET="$TELEGRAM_WEBHOOK_SECRET"
```

```bash
pnpm deploy:functions
```

```bash
./scripts/telegram-set-webhook.sh https://<prosjekt-ref>.supabase.co/functions/v1/telegram-webhook
```

Svaret fra `getWebhookInfo` skal vise riktig URL og `"pending_update_count":0`.

## 3. Cloudflare Workers (du)

Appen deployes som en Worker med statiske filer (`wrangler.jsonc`). Det er det Cloudflare foreslår som standard; Pages trengs ikke.

1. Workers & Pages → Create application → Import a repository → `mrjohnick/grannyapp`.
2. Build command: `pnpm build`. Deploy command: `npx wrangler deploy` (standard).
3. Advanced settings → **Build variables** (ikke runtime-variabler – Vite bygger dem inn i koden):

   | Navn | Verdi |
   | --- | --- |
   | `VITE_SUPABASE_URL` | Project URL fra Supabase |
   | `VITE_SUPABASE_PUBLISHABLE_KEY` | Publishable key |
   | `VITE_TELEGRAM_BOT_USERNAME` | Brukernavnet til boten, uten @ |

4. Deploy. Adressen blir `grannyapp.<konto>.workers.dev`. Sett den som Site URL i Supabase (steg 2.4).

Kartet bruker OpenStreetMap-fliser så lenge `VITE_PMTILES_URL` ikke er satt. Det er greit for en felttest med noen få personer, men ikke for selve spillet.

## 4. Felttest

**Før**

1. Kjør `scripts/felttest.sql` i Supabase → SQL Editor. Den lager et testspill og skriver ut koder for 6 testere, ett lag og spilleder.
2. Del én kode per tester (SMS eller lapp, ikke i repoet).

**Testerne**

1. Åpner app-adressen, skriver koden og følger skjermen «Del posisjonen din i Telegram».
2. Deler live-posisjon med boten, «Til jeg slår det av».
3. Låser telefonen og bruker den som vanlig. Appen trenger ikke være åpen.

Bland gjerne slik, så vi lærer mest:

| Tester | Telefon | Gjør |
| --- | --- | --- |
| 1 | iPhone | Går rundt i sentrum |
| 2 | iPhone | Står stille 20 min, så går |
| 3 | Android (Samsung) | Går rundt, batterisparing på |
| 4 | Android | Sitter i bil |
| 5 | Valgfri | Bruker andre apper mye (kamera, chat) |
| 6 | Valgfri | Sveiper bort Telegram etter 30 min (for å se at vi oppdager det) |

**Spilleder**

Logg inn med `FT-ADMIN-…`-koden på laptop. Under «Telegram-måling» vises for hver tester:

- **Median**: typisk tid mellom oppdateringer.
- **P90**: 9 av 10 hull er kortere enn dette.
- **Maks**: største hull (rødt over 3 min).
- **±m**: typisk nøyaktighet Telegram oppgir.

**Når er det godt nok?** Pingene kommer hvert 15., 10. og 5. minutt. Et forslag til krav:
median under 1 min mens man går, P90 under 3 min, og ingen faller ut med låst skjerm i løpet av en time.

**Etter**

Ta skjermbilde av tabellen (velg «Siste 60 min» eller «Siste 150 min»), og slett testdataene:

```sql
delete from public.games where name like 'Felttest %';
```
