// game-worker: sender Web Push for nye varsler, og rydder bilder i Storage
// for spill som er slettet etter 30 dager.
//
// Vekkes av databasen (pg_net) hver gang et varsel legges inn, og av pg_cron
// hvert minutt og hver natt. Funksjonen er åpen (verify_jwt = false), men den
// gjør bare ufarlige ting: sender varsler som venter, og rydder slettede spill.
//
// Miljøvariabler:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY  fra `npx web-push generate-vapid-keys`
//   VAPID_SUBJECT                        f.eks. https://grannyapp.example (valgfri)
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

type Sub = { endpoint: string; p256dh: string; auth: string };
type ClaimedEvent = { id: number; kind: string; title: string; body: string | null; subs: Sub[] };

async function sendPush(): Promise<{ events: number; sent: number; removed: number }> {
  if (!pushReady) return { events: 0, sent: 0, removed: 0 };
  const { data, error } = await supabase.rpc("worker_claim_events");
  if (error) throw new Error(`worker_claim_events: ${error.message}`);
  const events = (data ?? []) as ClaimedEvent[];
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
  return { events: events.length, sent, removed };
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
    const result = task === "purge" ? { files: await cleanStorage() } : await sendPush();
    return Response.json({ ok: true, task, ...result });
  } catch (err) {
    console.error(task, (err as Error).message);
    return Response.json({ ok: false, task }, { status: 500 });
  }
});
