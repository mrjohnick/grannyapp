// Spilleder (S1): bildekø, egne varsler, poengjustering og hendelseslogg.
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";
import { friendly } from "../lib/errors";
import { useInterval } from "../lib/hooks";
import { useEventVersion } from "../lib/events";
import { formatGameTime } from "../lib/gameClock";
import type { AdminLive, AdminPhoto, GameEvent } from "../lib/types";
import { Badge, Button, TeamDot } from "../components/ui";
import { StoredPhoto } from "./camera";

const field = "h-11 w-full rounded-sm border border-border-strong bg-bg-surface px-3 type-body-m";

// ---------------------------------------------------------------------------
// Bildekø
// ---------------------------------------------------------------------------
export function AdminPhotoQueue({ teams }: { teams: AdminLive["teams"] }) {
  const { version } = useEventVersion();
  const [photos, setPhotos] = useState<AdminPhoto[]>([]);
  const [target, setTarget] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("admin_photos");
    if (data) setPhotos(data as AdminPhoto[]);
  }, []);
  useInterval(load, 8000);
  useEffect(() => { if (version) load(); }, [version, load]);

  async function review(p: AdminPhoto, approve: boolean) {
    let note: string | null = null;
    if (!approve) {
      note = prompt("Kort begrunnelse til spilleren (valgfritt):", p.kind === "postkort" ? "Hele laget er ikke med." : "Lagfargen synes ikke.");
      if (note === null) return;
    }
    setBusy(p.id);
    const { error } = await supabase.rpc("admin_review_photo", {
      p_photo: p.id, p_approve: approve, p_target_team: target[p.id] ?? p.target_team_id, p_note: note,
    });
    setBusy(null);
    setError(friendly(error));
    load();
  }

  if (photos.length === 0) return null;
  return (
    <section className="flex flex-col gap-2">
      <h2 className="flex items-center gap-2 type-heading-m">Postkort <Badge tone="danger">{String(photos.length)}</Badge></h2>
      {error && <p className="type-body-s text-text-danger">{error}</p>}
      {photos.map((p) => (
        <div key={p.id} className="flex flex-col gap-2 rounded-lg border-2 border-border-strong bg-bg-app p-3">
          <div className="flex items-center justify-between gap-2">
            <Badge tone={p.kind === "postkort" ? "info" : "brand"}>
              {p.kind === "postkort" ? `Postkort ${p.postkort_number}` : "Fotoalbumet"}
            </Badge>
            <span className="type-timer-s text-text-tertiary" title="Når bildet ble sendt">
              {new Date(p.submitted_at).toLocaleTimeString("nb-NO", { hour: "2-digit", minute: "2-digit", second: "2-digit" })} · {formatGameTime(p.submitted_s)}
            </span>
          </div>
          {p.storage_path
            ? <StoredPhoto path={p.storage_path} className="max-h-80 w-full rounded-md object-contain" />
            : <p className="type-body-s text-text-tertiary">Sjekk gruppebildet i lagets Telegram-gruppe.</p>}
          {p.kind === "postkort" ? (
            <>
              <p className="flex items-center gap-2 type-label-m">{p.team_color && <TeamDot color={p.team_color} />} {p.team_name}</p>
              <p className="type-body-s text-text-secondary">{p.mission}</p>
              <p className={`type-body-s ${p.distance_m != null && p.zone_radius_m != null && p.distance_m <= p.zone_radius_m + 25 ? "text-text-success" : "text-text-danger"}`}>
                {p.distance_m == null ? "Ingen posisjon fulgte med." : `Levert ${Math.round(p.distance_m)} m fra stedet (radius ${p.zone_radius_m} m).`}
              </p>
              {(p.competing ?? 0) > 1 && <p className="type-body-s text-text-warning">{p.competing} lag venter på dette postkortet. Godkjenn det som ble levert først.</p>}
            </>
          ) : (
            <>
              <p className="type-label-m">Fra {p.granny_name}. Sjekk at lagfargen synes.</p>
              <select
                className={field}
                value={target[p.id] ?? p.target_team_id ?? ""}
                onChange={(e) => setTarget((t) => ({ ...t, [p.id]: e.target.value }))}
              >
                <option value="">Velg laget på bildet</option>
                {teams.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </select>
            </>
          )}
          <div className="flex gap-2">
            <Button size="M" icon="check" className="flex-1" disabled={busy === p.id} onClick={() => review(p, true)}>Godkjenn</Button>
            <Button size="M" variant="secondary" icon="x" disabled={busy === p.id} onClick={() => review(p, false)}>Avvis</Button>
          </div>
        </div>
      ))}
    </section>
  );
}

// ---------------------------------------------------------------------------
// Egne varsler og poeng
// ---------------------------------------------------------------------------
/** `only` viser bare det ene skjemaet (meldinger og poeng ligger på hver sin side hos spilleder). */
export function AdminTools({ live, only }: { live: AdminLive | null; only?: "broadcast" | "points" }) {
  const [audience, setAudience] = useState("all");
  const [text, setText] = useState("");
  const [who, setWho] = useState("");
  const [delta, setDelta] = useState("");
  const [reason, setReason] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const target = audience.startsWith("team:") ? { p_audience: "team", p_team: audience.slice(5) }
    : audience.startsWith("granny:") ? { p_audience: "granny", p_granny: audience.slice(7) }
    : { p_audience: audience };

  async function send(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    const { error } = await supabase.rpc("admin_broadcast", { ...target, p_text: text });
    setBusy(false);
    setMsg(error ? friendly(error) : "Varselet er sendt.");
    if (!error) setText("");
  }

  async function adjust(e: FormEvent) {
    e.preventDefault();
    const n = Number(delta);
    if (!who || !Number.isInteger(n) || n === 0) return setMsg("Velg hvem og skriv et helt tall, f.eks. -2 eller 5.");
    setBusy(true);
    const [kind, id] = who.split(":");
    const { error } = await supabase.rpc("admin_adjust_points", {
      p_delta: n, p_reason: reason, p_team: kind === "team" ? id : null, p_granny: kind === "granny" ? id : null,
    });
    setBusy(false);
    setMsg(error ? friendly(error) : `Poengene er justert (${n > 0 ? "+" : ""}${n}).`);
    if (!error) { setDelta(""); setReason(""); }
  }

  const options = (
    <>
      <optgroup label="Lag">{(live?.teams ?? []).map((t) => <option key={t.id} value={`team:${t.id}`}>{t.name}</option>)}</optgroup>
      <optgroup label="Grannies">{(live?.grannies ?? []).map((g) => <option key={g.id} value={`granny:${g.id}`}>{g.name}{g.is_romling ? " (Rømling)" : ""}</option>)}</optgroup>
    </>
  );

  return (
    <section className="flex flex-col gap-3 rounded-lg border border-border-default p-3">
      {only !== "points" && (<>
      <h2 className="type-heading-m">Send varsel</h2>
      <form onSubmit={send} className="flex flex-col gap-2">
        <select className={field} value={audience} onChange={(e) => setAudience(e.target.value)}>
          <option value="all">Alle</option>
          <option value="teams">Alle lag</option>
          <option value="grannies">Alle grannies</option>
          {options}
        </select>
        <textarea className={`${field} h-20 py-2`} value={text} onChange={(e) => setText(e.target.value)} placeholder="Meldingen" maxLength={500} />
        <Button size="M" icon="send" type="submit" disabled={busy || !text.trim()}>Send</Button>
      </form>
      </>)}
      {only !== "broadcast" && (<>
      <h2 className="type-heading-m">Juster poeng</h2>
      <form onSubmit={adjust} className="flex flex-col gap-2">
        <select className={field} value={who} onChange={(e) => setWho(e.target.value)}>
          <option value="">Velg lag eller granny</option>
          {options}
        </select>
        <div className="flex gap-2">
          <input className={`${field} w-24`} inputMode="numeric" value={delta} onChange={(e) => setDelta(e.target.value)} placeholder="±p" />
          <input className={field} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Hvorfor" maxLength={100} />
        </div>
        <Button size="M" variant="secondary" type="submit" disabled={busy}>Lagre</Button>
      </form>
      </>)}
      {msg && <p className="type-body-s text-text-secondary">{msg}</p>}
    </section>
  );
}

// ---------------------------------------------------------------------------
// Hendelseslogg (spilleder ser alle varsler)
// ---------------------------------------------------------------------------
export function AdminEventLog() {
  const { last } = useEventVersion();
  const [events, setEvents] = useState<GameEvent[]>([]);
  useEffect(() => {
    supabase.rpc("my_events", { p_after: 0 }).then(({ data }) => data && setEvents((data as GameEvent[]).slice(-30).reverse()));
  }, [last?.id]);
  if (events.length === 0) return null;
  return (
    <section>
      <h2 className="mb-2 type-heading-m">Siste 15 min</h2>
      <ul className="flex flex-col gap-1">
        {events.map((e) => (
          <li key={e.id} className="flex gap-2 type-body-s">
            <span className="w-10 shrink-0 type-timer-s text-text-tertiary">{formatGameTime(e.at_s)}</span>
            <span><span className="font-semibold">{e.title}</span> {e.body}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Vis en granny live for alle lag
// ---------------------------------------------------------------------------
export function AdminReveal({ live }: { live: AdminLive | null }) {
  const [granny, setGranny] = useState("");
  const [minutes, setMinutes] = useState("2");
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const free = (live?.grannies ?? []).filter((g) => !g.is_romling && g.caught_at_s == null);
  const liveNow = free.filter((g) => g.live_reason === "spilleder");

  async function reveal(e: FormEvent) {
    e.preventDefault();
    const n = Number(minutes);
    if (!granny || !Number.isInteger(n) || n < 1 || n > 30) return setMsg("Velg en granny og 1–30 minutter.");
    setBusy(true);
    const { error } = await supabase.rpc("admin_reveal_granny", { p_granny: granny, p_minutes: n });
    setBusy(false);
    const name = free.find((g) => g.id === granny)?.name;
    setMsg(error ? friendly(error) : `${name} er live for alle lag i ${n} min.`);
    if (!error) setGranny("");
  }

  return (
    <section className="flex flex-col gap-2 rounded-lg border border-border-default p-3">
      <h2 className="type-heading-m">Vis granny live</h2>
      <p className="type-body-s text-text-secondary">Lagene ser posisjonen hele tiden, ikke bare ved ping.</p>
      <form onSubmit={reveal} className="flex flex-col gap-2">
        <select className={field} value={granny} onChange={(e) => setGranny(e.target.value)}>
          <option value="">Velg granny</option>
          {free.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
        </select>
        <div className="flex gap-2">
          <label className="flex items-center gap-2 type-body-s">
            <input className={`${field} w-20`} inputMode="numeric" value={minutes} onChange={(e) => setMinutes(e.target.value)} /> min
          </label>
          <Button size="M" icon="eye" type="submit" className="flex-1" disabled={busy || !granny}>Vis live</Button>
        </div>
      </form>
      {liveNow.length > 0 && <p className="type-body-s">Live nå: {liveNow.map((g) => g.name).join(", ")}</p>}
      {msg && <p className="type-body-s text-text-secondary">{msg}</p>}
    </section>
  );
}
