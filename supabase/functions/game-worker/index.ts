// game-worker: sender nye varsler som Web Push og Telegram-meldinger, og
// rydder bilder i Storage for spill som er slettet etter 30 dager.
//
// Vekkes av databasen (pg_net) hver gang et varsel legges inn, og av pg_cron
// hvert minutt og hver natt. Funksjonen er åpen (verify_jwt = false), men den
// gjør bare ufarlige ting: sender varsler som venter, og rydder slettede spill.
//
// Miljøvariabler:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY  fra `npx web-push generate-vapid-keys`
//   VAPID_SUBJECT                        f.eks. https://grannyapp.example (valgfri)
//   TELEGRAM_BOT_TOKEN                   samme bot som telegram-webhook (valgfri)
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY / SUPABASE_SECRET_KEYS  settes av Supabase

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const json = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (json) {
    try {
      const first = Object.values(JSON.parse(json) as Record<string, string>)[0];
      if (first) return first;
    } catch { /* faller gjennom */ }
  }
  throw new Error("Fant ingen service-nøkkel");
}

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });

const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const pushReady = Boolean(VAPID_PUBLIC && VAPID_PRIVATE);
// web-push krever https: eller mailto: (localhost godtas ikke).
const subject = Deno.env.get("VAPID_SUBJECT") ?? "";
if (pushReady) {
  webpush.setVapidDetails(/^(https:|mailto:)/.test(subject) ? subject : "https://grannyapp.invalid", VAPID_PUBLIC, VAPID_PRIVATE);
}

const BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const telegramReady = Boolean(BOT_TOKEN);

type Sub = { endpoint: string; p256dh: string; auth: string };
type ClaimedEvent = { id: number; kind: string; title: string; body: string | null; subs: Sub[]; chats: number[] };

async function sendAll() {
  if (!pushReady && !telegramReady) return { events: 0, sent: 0, removed: 0, telegram: 0 };
  const { data, error } = await supabase.rpc("worker_claim_events");
  if (error) throw new Error(`worker_claim_events: ${error.message}`);
  const events = (data ?? []) as ClaimedEvent[];
  const [push, telegram] = await Promise.all([sendPush(events), sendTelegram(events)]);
  return { events: events.length, ...push, telegram };
}

async function sendPush(events: ClaimedEvent[]): Promise<{ sent: number; removed: number }> {
  if (!pushReady) return { sent: 0, removed: 0 };
  let sent = 0, removed = 0;

  await Promise.all(events.flatMap((e) =>
    e.subs.map(async (s) => {
      const payload = JSON.stringify({ title: e.title, body: e.body ?? "", tag: `${e.kind}-${e.id}`, kind: e.kind });
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload,
          { TTL: 300, urgency: "high" });
        sent++;
      } catch (err) {
        const status = (err as { statusCode?: number }).statusCode;
        if (status === 404 || status === 410) {
          await supabase.rpc("worker_remove_subscription", { p_endpoint: s.endpoint });
          removed++;
        } else {
          console.error("push feilet", status, (err as Error).message);
        }
      }
    })
  ));
  return { sent, removed };
}

// Telegram tåler rundt 30 meldinger i sekundet fra én bot. Vi sender én og én
// med litt pause, og venter når Telegram ber om det (429).
const TG_GAP_MS = 40;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

async function tgSend(chatId: number, text: string): Promise<"ok" | "blocked" | "failed"> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const res = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML", link_preview_options: { is_disabled: true } }),
    });
    if (res.ok) return "ok";
    const body = await res.json().catch(() => ({})) as { description?: string; parameters?: { retry_after?: number } };
    if (res.status === 429) { await sleep((body.parameters?.retry_after ?? 1) * 1000); continue; }
    // Brukeren har blokkert boten eller slettet chatten.
    if (res.status === 403 || (res.status === 400 && /chat not found/i.test(body.description ?? ""))) return "blocked";
    console.error("telegram feilet", res.status, body.description);
    return "failed";
  }
  return "failed";
}

async function sendTelegram(events: ClaimedEvent[]): Promise<number> {
  if (!telegramReady) return 0;
  let sent = 0;
  const blocked = new Set<number>();
  for (const e of events) {
    const text = `<b>${esc(e.title)}</b>${e.body ? `\n${esc(e.body)}` : ""}`;
    for (const chat of e.chats ?? []) {
      if (blocked.has(chat)) continue;
      const result = await tgSend(chat, text);
      if (result === "ok") sent++;
      if (result === "blocked") {
        blocked.add(chat);
        await supabase.rpc("worker_telegram_blocked", { p_chat_id: chat });
      }
      await sleep(TG_GAP_MS);
    }
  }
  return sent;
}

async function cleanStorage(): Promise<number> {
  const { data, error } = await supabase.rpc("worker_storage_to_clean");
  if (error) throw new Error(`worker_storage_to_clean: ${error.message}`);
  let removed = 0;
  for (const gameId of (data ?? []) as string[]) {
    for (;;) {
      const { data: files, error: listError } = await supabase.storage.from("photos").list(gameId, { limit: 100 });
      if (listError) throw new Error(`list: ${listError.message}`);
      if (!files || files.length === 0) break;
      const { error: rmError } = await supabase.storage.from("photos").remove(files.map((f) => `${gameId}/${f.name}`));
      if (rmError) throw new Error(`remove: ${rmError.message}`);
      removed += files.length;
    }
    await supabase.rpc("worker_mark_cleaned", { p_game: gameId });
  }
  return removed;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  let task = "push";
  try {
    task = ((await req.json()) as { task?: string }).task ?? "push";
  } catch { /* tom body */ }

  try {
    const result = task === "purge" ? { files: await cleanStorage() } : await sendAll();
    return Response.json({ ok: true, task, ...result });
  } catch (err) {
    console.error(task, (err as Error).message);
    return Response.json({ ok: false, task }, { status: 500 });
  }
});
