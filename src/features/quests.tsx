// Side quests: spilleder lager oppdrag, laget sender bilde eller video, spilleder godkjenner
// og gir poeng og/eller evnen «se granny live». Laget velger selv hvilken granny evnen gjelder.
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";
import { friendly } from "../lib/errors";
import { useInterval } from "../lib/hooks";
import { useEventVersion } from "../lib/events";
import { tagText, useFamilies } from "../lib/families";
import { formatGameTime } from "../lib/gameClock";
import type { AdminLive, AdminQuest, QuestSubmission, TeamQuests } from "../lib/types";
import { Badge, Button, Sheet, TeamDot } from "../components/ui";
import { Avatar } from "../components/Avatar";
import { CameraCapture, MAX_VIDEO_MB, StoredMedia, uploadPhoto, uploadVideo } from "./camera";

const field = "h-11 w-full rounded-sm border border-border-strong bg-bg-surface px-3 type-body-m";

function rewardText(points: number, abilities: number) {
  return [points > 0 ? `${points}p` : null, abilities > 0 ? `${abilities} × se granny live` : null].filter(Boolean).join(" + ");
}

function secondsText(s: number) {
  return s % 60 === 0 ? `${s / 60} min` : `${s} sek`;
}

// ---------------------------------------------------------------------------
// Laget
// ---------------------------------------------------------------------------
export function QuestSheet({ gameId, blind, onClose, onChanged }: {
  gameId: string;
  blind: boolean;
  onClose: () => void;
  onChanged: () => void;
}) {
  const { version } = useEventVersion();
  const [data, setData] = useState<TeamQuests | null>(null);
  const [camera, setCamera] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const videoInput = useRef<HTMLInputElement>(null);
  const videoFor = useRef<string | null>(null);

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("team_quests");
    if (data) setData(data as TeamQuests);
  }, []);
  useEffect(() => { load(); }, [load, version]);

  async function submit(questId: string, path: string, media: "image" | "video") {
    const { error } = await supabase.rpc("submit_quest", { p_quest: questId, p_path: path, p_media: media });
    if (error) throw new Error(friendly(error) ?? "Noe gikk galt.");
    setMsg("Sendt! Spilleder sjekker beviset.");
    load();
    onChanged();
  }

  async function onVideo(file: File | undefined) {
    const questId = videoFor.current;
    if (!file || !questId) return;
    setBusy(questId);
    setError(null);
    try {
      const path = await uploadVideo(gameId, file);
      await submit(questId, path, "video");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(null);
      if (videoInput.current) videoInput.current.value = "";
    }
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Side quests</h2>
      {data && data.abilities_left > 0 && (
        <AbilityPanel left={data.abilities_left} liveS={data.ability_live_s} blind={blind}
          onUsed={(m) => { setMsg(m); load(); onChanged(); }} />
      )}
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
              <Badge tone="brand">{rewardText(q.reward_points, q.reward_abilities)}</Badge>
            </div>
            {q.description && <p className="type-body-s text-text-secondary">{q.description}</p>}
            {q.status === "pending" && <Badge tone="warning">Venter på spilleder</Badge>}
            {q.status === "approved" && <Badge tone="success">Godkjent</Badge>}
            {q.status === "rejected" && <p className="type-body-s text-text-danger">Ikke godkjent{q.note ? `: ${q.note}` : ""}. Prøv igjen.</p>}
            {open && (
              <div className="flex gap-2">
                <Button size="M" icon="camera" className="flex-1" disabled={busy === q.id} onClick={() => setCamera(q.id)}>Bilde</Button>
                <Button size="M" variant="secondary" className="flex-1" disabled={busy === q.id}
                  onClick={() => { videoFor.current = q.id; videoInput.current?.click(); }}>
                  {busy === q.id ? "Laster opp …" : "Video"}
                </Button>
              </div>
            )}
          </div>
        );
      })}
      <p className="type-body-s text-text-tertiary">Video: maks {MAX_VIDEO_MB} MB. Hold den kort.</p>
      <input ref={videoInput} type="file" accept="video/*" capture="environment" className="hidden"
        onChange={(e) => onVideo(e.target.files?.[0])} />
      {camera && (
        <CameraCapture
          title="Bevis"
          hint="Ta bilde av at dere har løst oppdraget."
          onClose={() => setCamera(null)}
          onSend={async (blob) => {
            const path = await uploadPhoto(gameId, blob, "quest-");
            await submit(camera, path, "image");
            setCamera(null);
          }}
        />
      )}
    </Sheet>
  );
}

function AbilityPanel({ left, liveS, blind, onUsed }: { left: number; liveS: number; blind: boolean; onUsed: (msg: string) => void }) {
  const { tagOf, avatarOf } = useFamilies();
  const [grannies, setGrannies] = useState<Array<{ id: string; name: string }> | null>(null);
  const [choice, setChoice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    supabase.from("grannies").select("id, name, is_romling, caught_at_s").then(({ data }) => {
      const rows = (data ?? []) as Array<{ id: string; name: string; is_romling: boolean; caught_at_s: number | null }>;
      setGrannies(rows.filter((g) => !g.is_romling && g.caught_at_s == null).sort((a, b) => a.name.localeCompare(b.name, "nb")));
    });
  }, []);

  async function use() {
    if (!choice) return;
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc("team_use_ability", { p_granny: choice });
    setBusy(false);
    if (error) return setError(friendly(error));
    const name = grannies?.find((g) => g.id === choice)?.name;
    onUsed(`Dere ser ${name} live i ${secondsText(liveS)}. Se kartet!`);
  }

  return (
    <div className="flex flex-col gap-2 rounded-lg border-2 border-border-strong bg-bg-accent p-3">
      <div className="flex items-baseline justify-between">
        <span className="type-label-l">Se granny live</span>
        <span className="type-label-m">{left} igjen</span>
      </div>
      <p className="type-body-s">Velg en granny. Dere ser henne på kartet i {secondsText(liveS)}, og hun får beskjed.</p>
      {blind && <p className="type-body-s">Dere er blinde nå. Vent til blindheten er over.</p>}
      <div className="flex max-h-48 flex-col gap-1 overflow-y-auto">
        {grannies?.map((g) => (
          <button key={g.id} type="button" onClick={() => setChoice(g.id)}
            className={`flex items-center gap-2 rounded-md border-2 px-2 py-1 text-left ${choice === g.id ? "border-border-strong bg-bg-surface" : "border-transparent"}`}>
            <Avatar name={g.name} url={avatarOf(g.id)} size={28} />
            <span className="flex-1 type-label-m">{g.name}</span>
            <span className="type-body-s text-text-secondary">{tagText(tagOf(g.id))}</span>
          </button>
        ))}
      </div>
      {error && <p className="type-body-s text-text-danger">{error}</p>}
      <Button size="M" icon="eye" disabled={!choice || busy || blind} onClick={use}>Se live nå</Button>
    </div>
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
  const [abilities, setAbilities] = useState("1");
  const [team, setTeam] = useState("");
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
    const { error } = await supabase.rpc("admin_save_quest", {
      p_id: null, p_title: title, p_description: description, p_points: Number(points) || 0,
      p_abilities: Number(abilities) || 0, p_team: team || null,
    });
    setBusy(false);
    setMsg(error ? friendly(error) : "Oppdraget er sendt til lagene.");
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
        <textarea className={`${field} h-16 py-2`} value={description} onChange={(e) => setDescription(e.target.value)} placeholder="Hva skal laget gjøre? (valgfritt)" maxLength={400} />
        <div className="flex gap-2">
          <label className="flex flex-1 flex-col gap-1 type-label-s">Poeng
            <input className={field} inputMode="numeric" value={points} onChange={(e) => setPoints(e.target.value)} />
          </label>
          <label className="flex flex-1 flex-col gap-1 type-label-s">Se granny live
            <input className={field} inputMode="numeric" value={abilities} onChange={(e) => setAbilities(e.target.value)} />
          </label>
        </div>
        <select className={field} value={team} onChange={(e) => setTeam(e.target.value)}>
          <option value="">Alle lag</option>
          {(live?.teams ?? []).map((t) => <option key={t.id} value={t.id}>Bare {t.name}</option>)}
        </select>
        <Button size="M" icon="send" type="submit" disabled={busy || !title.trim()}>Send oppdraget</Button>
      </form>
      {msg && <p className="type-body-s text-text-secondary">{msg}</p>}
      {quests.length > 0 && (
        <ul className="flex flex-col gap-1">
          {quests.map((q) => (
            <li key={q.id} className={`flex items-start gap-2 rounded-md px-2 py-1 ${q.closed ? "opacity-50" : ""}`}>
              <div className="flex-1">
                <div className="type-label-s">{q.title} <span className="font-normal text-text-secondary">· {rewardText(q.reward_points, q.reward_abilities)}{q.team_name ? ` · bare ${q.team_name}` : ""}</span></div>
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
      note = prompt("Kort begrunnelse til laget (valgfritt):", "Vi ser ikke at oppdraget er løst.");
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
            <span className="flex items-center gap-2 type-label-m"><TeamDot color={s.team_color} /> {s.team_name}</span>
            <span className="type-timer-s text-text-tertiary">{formatGameTime(s.submitted_s)}</span>
          </div>
          <p className="type-label-m">{s.quest_title} <span className="font-normal text-text-secondary">· {rewardText(s.reward_points, s.reward_abilities)}</span></p>
          {s.quest_description && <p className="type-body-s text-text-secondary">{s.quest_description}</p>}
          <StoredMedia path={s.storage_path} media={s.media} className="max-h-80 w-full rounded-md object-contain" />
          <div className="flex gap-2">
            <Button size="M" icon="check" className="flex-1" disabled={busy === s.id} onClick={() => review(s, true)}>Godkjenn</Button>
            <Button size="M" variant="secondary" icon="x" disabled={busy === s.id} onClick={() => review(s, false)}>Avvis</Button>
          </div>
        </div>
      ))}
    </section>
  );
}
