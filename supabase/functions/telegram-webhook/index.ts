// Telegram-webhook for GrannyBot.
//
// Grannyene deler live-posisjon med boten i privat chat. Telegram sender
// første posisjon som `message` og hver oppdatering som `edited_message`.
// Vi lagrer alle som posisjoner med kilde «telegram».
//
// Miljøvariabler:
//   TELEGRAM_BOT_TOKEN       fra @BotFather
//   TELEGRAM_WEBHOOK_SECRET  samme verdi som secret_token i setWebhook
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  settes automatisk av Supabase

import { createClient } from "npm:@supabase/supabase-js@2";

const BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const WEBHOOK_SECRET = Deno.env.get("TELEGRAM_WEBHOOK_SECRET") ?? "";

// Prosjekter uten de gamle JWT-nøklene får bare de nye «secret keys»
// (SUPABASE_SECRET_KEYS, JSON). Vi støtter begge.
function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const json = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (json) {
    try {
      const first = Object.values(JSON.parse(json) as Record<string, string>)[0];
      if (first) return first;
    } catch { /* faller gjennom til feilen under */ }
  }
  throw new Error("Fant ingen service-nøkkel (SUPABASE_SERVICE_ROLE_KEY eller SUPABASE_SECRET_KEYS)");
}

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), {
  auth: { persistSession: false },
});

type TgLocation = {
  latitude: number;
  longitude: number;
  horizontal_accuracy?: number;
  live_period?: number;
};

type TgMessage = {
  message_id: number;
  date: number;
  edit_date?: number;
  chat: { id: number; type: "private" | "group" | "supergroup" | "channel" };
  from?: { id: number };
  text?: string;
  location?: TgLocation;
};

type TgUpdate = {
  update_id: number;
  message?: TgMessage;
  edited_message?: TgMessage;
};

const TEXT = {
  linked: (name: string) =>
    `Hei, ${name}! Nå: trykk ⊕ → Posisjon → «Del live-posisjon» → «Til jeg slår det av». Del bare her, aldri i lag-gruppa.`,
  badToken: "Den lenken kjenner jeg ikke igjen. Åpne den på nytt fra appen.",
  notLinked: "Jeg vet ikke hvem du er ennå. Åpne lenken fra appen først.",
  notLive:
    "Det var bare én posisjon. Del live-posisjon i stedet: ⊕ → Posisjon → «Del live-posisjon» → «Til jeg slår det av».",
  live: "Takk! Du er med på pingene. Ikke sveip bort Telegram – da stopper delingen.",
  help: "Åpne lenken fra appen for å koble deg til, og del så live-posisjon her.",
};

async function reply(chatId: number, text: string) {
  if (!BOT_TOKEN) return;
  const res = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text }),
  });
  if (!res.ok) console.error("sendMessage feilet", res.status, await res.text());
}

async function handle(update: TgUpdate) {
  const msg = update.message ?? update.edited_message;
  if (!msg?.from) return;
  const isEdit = !update.message;

  // Posisjon i en gruppe er allerede synlig for laget. Vi bruker den ikke.
  if (msg.chat.type !== "private") return;

  if (msg.text?.startsWith("/start")) {
    const token = msg.text.split(/\s+/)[1];
    if (!token) return reply(msg.chat.id, TEXT.help);
    const { data, error } = await supabase.rpc("telegram_link", {
      p_token: token,
      p_user_id: msg.from.id,
      p_chat_id: msg.chat.id,
    });
    if (error) throw error;
    return reply(msg.chat.id, data?.ok ? TEXT.linked(data.granny_name) : TEXT.badToken);
  }

  if (msg.location) {
    const at = new Date((msg.edit_date ?? msg.date) * 1000).toISOString();
    const { data, error } = await supabase.rpc("telegram_ingest_location", {
      p_user_id: msg.from.id,
      p_lat: msg.location.latitude,
      p_lng: msg.location.longitude,
      p_accuracy: msg.location.horizontal_accuracy ?? null,
      p_live_period: msg.location.live_period ?? null,
      p_at: at,
    });
    if (error) throw error;
    // Svar bare på første melding, ikke på hver oppdatering.
    if (isEdit) return;
    if (!data?.ok) return reply(msg.chat.id, TEXT.notLinked);
    return reply(msg.chat.id, data.is_live ? TEXT.live : TEXT.notLive);
  }

  if (!isEdit) return reply(msg.chat.id, TEXT.help);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  if (!WEBHOOK_SECRET || req.headers.get("x-telegram-bot-api-secret-token") !== WEBHOOK_SECRET) {
    return new Response("forbidden", { status: 401 });
  }

  let update: TgUpdate;
  try {
    update = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }

  try {
    await handle(update);
  } catch (err) {
    // Svar 200 likevel: Telegram prøver ellers på nytt i det uendelige, og en
    // tapt posisjon erstattes uansett av neste oppdatering.
    console.error("webhook-feil", update.update_id, err);
  }
  return new Response("ok");
});
