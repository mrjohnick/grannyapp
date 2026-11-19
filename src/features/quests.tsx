// Side quests: spilleder lager oppdrag til lag eller grannyer. De sender beviset i Telegram og
// trykker «Marker som levert». Spilleder godkjenner og gir poeng.
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";
import { friendly } from "../lib/errors";
import { useInterval } from "../lib/hooks";
import { useEventVersion } from "../lib/events";
import { formatGameTime } from "../lib/gameClock";
import type { AbilityKind, AdminLive, AdminQuest, QuestSubmission, TeamQuests } from "../lib/types";
import { ABILITY_TEXT } from "./abilities";
import { Badge, Button, Sheet, TeamDot } from "../components/ui";
import { StoredMedia } from "./camera";

const field = "h-11 w-full rounded-sm border border-border-strong bg-bg-surface px-3 type-body-m";

function rewardText(points: number, abilities = 0, kind?: AbilityKind) {
  return [points > 0 ? `${points}p` : null, abilities > 0 && kind ? `${abilities} × ${ABILITY_TEXT[kind].title.toLowerCase()}` : null]
    .filter(Boolean).join(" + ");
}

// ---------------------------------------------------------------------------
// Laget og grannyene: marker et oppdrag som levert. Beviset sendes i Telegram.
// ---------------------------------------------------------------------------
export function QuestSheet({ role, onClose, onChanged }: {
  role: "team" | "granny";
  onClose: () => void;
  onChanged: () => void;
}) {
  const { version } = useEventVersion();
  const [data, setData] = useState<TeamQuests | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data } = await supabase.rpc(role === "team" ? "team_quests" : "granny_quests");
    if (data) setData(data as TeamQuests);
  }, [role]);
  useEffect(() => { load(); }, [load, version]);

  async function deliver(questId: string, title: string) {
    if (!confirm(`Marker «${title}» som levert? Husk å sende bildet eller videoen i Telegram-gruppa først.`)) return;
    setBusy(questId);
    setError(null);
    const { error } = await supabase.rpc("deliver_quest", { p_quest: questId });
    setBusy(null);
    if (error) return setError(friendly(error) ?? "Noe gikk galt.");
    setMsg("Levert! Du får poengene når spilleder har godkjent.");
    load();
    onChanged();
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Oppdrag</h2>
      <p className="type-body-s text-text-secondary">
        Send bildet eller videoen i {role === "team" ? "lagets Telegram-gruppe" : "Telegram-gruppa"}, og trykk så «Marker som levert». Poengene kommer når spilleder har godkjent.
      </p>
      {msg && <p className="rounded-md bg-bg-success-subtle p-3 type-body-s">{msg}</p>}
      {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
      {data === null && <p className="type-body-m text-text-tertiary">Henter oppdrag …</p>}
      {data?.quests.length === 0 && <p className="type-body-m text-text-secondary">Ingen oppdrag ennå. Spilleder sender dem underveis.</p>}
      {data?.quests.map((q) => {
        const open = !q.closed && q.status !== "pending" && q.status !== "approved";
        return (
          <div key={q.id} className="flex flex-col gap-2 rounded-lg border-2 border-border-strong p-3">
            <div className="flex items-start justify-between gap-2">
              <span className="type-label-l">{q.title}</span>
              <Badge tone="brand">{rewardText(q.reward_points, q.reward_abilities, q.reward_ability_kind)}</Badge>
            </div>
            {q.description && <p className="type-body-s text-text-secondary">{q.description}</p>}
            {q.status === "pending" && <Badge tone="warning">Levert – venter på spilleder</Badge>}
            {q.status === "approved" && <Badge tone="success">Godkjent</Badge>}
            {q.status === "rejected" && <p className="type-body-s text-text-danger">Ikke godkjent{q.note ? `: ${q.note}` : ""}. Prøv igjen.</p>}
            {open && (
              <Button size="M" icon="check" disabled={busy === q.id} onClick={() => deliver(q.id, q.title)}>
                {busy === q.id ? "Sender …" : "Marker som levert"}
              </Button>
            )}
          </div>
        );
      })}
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Spilleder: lag oppdrag og godkjenn bevis
// ---------------------------------------------------------------------------
export function AdminQuests({ live }: { live: AdminLive | null }) {
  const { version } = useEventVersion();
  const [quests, setQuests] = useState<AdminQuest[]>([]);
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [points, setPoints] = useState("3");
  // «teams», «grannies», «team:<id>» eller «granny:<id>»
  const [target, setTarget] = useState("teams");
  const [abilityKind, setAbilityKind] = useState<AbilityKind | "">("");
  const [abilityCount, setAbilityCount] = useState("1");
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("admin_quests");
    if (data) setQuests(data as AdminQuest[]);
  }, []);
  useInterval(load, 15_000);
  useEffect(() => { load(); }, [load, version]);

  async function create(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    const [kind, id] = target.split(":");
    const toGrannies = kind === "grannies" || kind === "granny";
    const { error } = await supabase.rpc("admin_save_quest", {
      p_id: null, p_title: title, p_description: description, p_points: Number(points) || 0,
      p_abilities: !toGrannies && abilityKind ? Number(abilityCount) || 0 : 0,
      p_ability_kind: abilityKind || "live",
      p_team: kind === "team" ? id : null, p_granny: kind === "granny" ? id : null,
      p_audience: toGrannies ? "grannies" : "teams",
    });
    setBusy(false);
    setMsg(error ? friendly(error) : toGrannies ? "Oppdraget er sendt til grannyene." : "Oppdraget er sendt til lagene.");
    if (!error) { setTitle(""); setDescription(""); }
    load();
  }

  async function toggle(q: AdminQuest) {
    const { error } = await supabase.rpc("admin_close_quest", { p_id: q.id, p_closed: !q.closed });
    setMsg(error ? friendly(error) : q.closed ? "Oppdraget er åpnet igjen." : "Oppdraget er stengt.");
    load();
  }

  return (
    <section className="flex flex-col gap-3 rounded-lg border border-border-default p-3">
      <h2 className="type-heading-m">Side quests</h2>
      <form onSubmit={create} className="flex flex-col gap-2">
        <input className={field} value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Tittel, f.eks. «Syng for en fremmed»" maxLength={80} />
        <textarea className={`${field} h-16 py-2`} value={description} onChange={(e) => setDescription(e.target.value)} placeholder="Hva skal de gjøre? (valgfritt)" maxLength={400} />
        <div className="flex gap-2">
          <label className="flex w-20 flex-col gap-1 type-label-s">Poeng
            <input className={field} inputMode="numeric" value={points} onChange={(e) => setPoints(e.target.value)} />
          </label>
          {!target.startsWith("granny") && (
            <>
              <label className="flex flex-1 flex-col gap-1 type-label-s">Evne (til lag)
                <select className={field} value={abilityKind} onChange={(e) => setAbilityKind(e.target.value as AbilityKind | "")}>
                  <option value="">Ingen</option>
                  {(Object.keys(ABILITY_TEXT) as AbilityKind[]).map((k) => <option key={k} value={k}>{ABILITY_TEXT[k].title}</option>)}
                </select>
              </label>
              {abilityKind && (
                <label className="flex w-16 flex-col gap-1 type-label-s">Antall
                  <input className={field} inputMode="numeric" value={abilityCount} onChange={(e) => setAbilityCount(e.target.value)} />
                </label>
              )}
            </>
          )}
        </div>
        <select className={field} value={target} onChange={(e) => setTarget(e.target.value)}>
          <option value="teams">Alle lag</option>
          <option value="grannies">Alle grannies</option>
          <optgroup label="Ett lag">
            {(live?.teams ?? []).map((t) => <option key={t.id} value={`team:${t.id}`}>Bare {t.name}</option>)}
          </optgroup>
          <optgroup label="Én granny">
            {(live?.grannies ?? []).filter((g) => !g.is_romling && g.caught_at_s == null)
              .map((g) => <option key={g.id} value={`granny:${g.id}`}>Bare {g.name}</option>)}
          </optgroup>
        </select>
        <Button size="M" icon="send" type="submit" disabled={busy || !title.trim()}>Send oppdraget</Button>
      </form>
      {msg && <p className="type-body-s text-text-secondary">{msg}</p>}
      {quests.length > 0 && (
        <ul className="flex flex-col gap-1">
          {quests.map((q) => (
            <li key={q.id} className={`flex items-start gap-2 rounded-md px-2 py-1 ${q.closed ? "opacity-50" : ""}`}>
              <div className="flex-1">
                <div className="type-label-s">{q.title} <span className="font-normal text-text-secondary">· {rewardText(q.reward_points, q.reward_abilities, q.reward_ability_kind)} · {q.team_name ? `bare ${q.team_name}` : q.granny_name ? `bare ${q.granny_name}` : q.audience === "grannies" ? "alle grannies" : "alle lag"}</span></div>
                <div className="type-body-s text-text-tertiary">
                  {q.approved_teams.length > 0 ? `Løst av ${q.approved_teams.join(", ")}` : "Ingen har løst det ennå"}
                  {q.pending > 0 ? ` · ${q.pending} venter` : ""}
                </div>
              </div>
              <button type="button" className="type-label-s text-text-brand" onClick={() => toggle(q)}>{q.closed ? "Åpne" : "Steng"}</button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

export function AdminQuestQueue() {
  const { version } = useEventVersion();
  const [items, setItems] = useState<QuestSubmission[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("admin_quest_queue");
    if (data) setItems(data as QuestSubmission[]);
  }, []);
  useInterval(load, 8000);
  useEffect(() => { if (version) load(); }, [version, load]);

  async function review(s: QuestSubmission, approve: boolean) {
    let note: string | null = null;
    if (!approve) {
      note = prompt("Kort begrunnelse (valgfritt):", "Vi ser ikke at oppdraget er løst.");
      if (note === null) return;
    }
    setBusy(s.id);
    const { error } = await supabase.rpc("admin_review_quest", { p_submission: s.id, p_approve: approve, p_note: note });
    setBusy(null);
    setError(friendly(error));
    load();
  }

  if (items.length === 0) return null;
  return (
    <section className="flex flex-col gap-2">
      <h2 className="flex items-center gap-2 type-heading-m">Side quests <Badge tone="danger">{String(items.length)}</Badge></h2>
      {error && <p className="type-body-s text-text-danger">{error}</p>}
      {items.map((s) => (
        <div key={s.id} className="flex flex-col gap-2 rounded-lg border-2 border-border-strong bg-bg-app p-3">
          <div className="flex items-center justify-between gap-2">
            <span className="flex items-center gap-2 type-label-m">
              {s.team_color && <TeamDot color={s.team_color} />} {s.team_name ?? `${s.granny_name} (granny)`}
            </span>
            <span className="type-timer-s text-text-tertiary">{formatGameTime(s.submitted_s)}</span>
          </div>
          <p className="type-label-m">{s.quest_title} <span className="font-normal text-text-secondary">· {rewardText(s.reward_points)}</span></p>
          {s.quest_description && <p className="type-body-s text-text-secondary">{s.quest_description}</p>}
          {s.storage_path && s.media
            ? <StoredMedia path={s.storage_path} media={s.media} className="max-h-80 w-full rounded-md object-contain" />
            : <p className="type-body-s text-text-tertiary">Sjekk beviset i Telegram-gruppa.</p>}
          <div className="flex gap-2">
            <Button size="M" icon="check" className="flex-1" disabled={busy === s.id} onClick={() => review(s, true)}>Godkjenn</Button>
            <Button size="M" variant="secondary" icon="x" disabled={busy === s.id} onClick={() => review(s, false)}>Avvis</Button>
          </div>
        </div>
      ))}
    </section>
  );
}
