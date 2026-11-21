// Fangst: L2 (lag registrerer), G6 (fanget), S1-kø. Bildet sendes i lagets Telegram-gruppe,
// og bare spilleder godkjenner fangsten.
import { useCallback, useEffect, useState } from "react";
import { supabase } from "../lib/supabase";
import { useFamilies, type GrannyTag } from "../lib/families";
import { useInterval } from "../lib/hooks";
import { formatGameTime } from "../lib/gameClock";
import { useGame } from "../lib/game";
import type { AdminCatch, CatchTarget, GameState, TeamCatch } from "../lib/types";
import { Badge, Button, Initial, SelectRow, Sheet, TeamDot } from "../components/ui";
import { Icon } from "../components/Icon";
import { Avatar } from "../components/Avatar";
import { StoredPhoto } from "./camera";

const ERRORS: Record<string, string> = {
  "Spillet er ikke i gang": "Spillet er ikke i gang. Vent til spilleder starter eller fortsetter.",
  "Jakten har ikke startet": "Jakten starter 0:15. Grannyene har fortsatt forsprang.",
  "Hun er allerede fanget": "Hun er allerede fanget.",
  "Krever lisens": "Rømlingen kan bare fanges med lisens fra Nattevakten.",
  "Kravet er ikke åpent lenger": "Det kravet er ikke åpent lenger. Spilleder har kanskje avgjort det.",
  "Ugyldig bilde": "Selfien ble ikke godtatt. Ta en ny.",
  "Hun er fredet": "Hun ble nettopp tatt og er fredet en stund.",
  "Dere har allerede tatt henne": "Dere har allerede fått poeng for henne.",
};
const friendly = (msg: string) => ERRORS[msg] ?? "Noe gikk galt. Prøv igjen.";

// ---------------------------------------------------------------------------
// L2 · Registrer fangst
// ---------------------------------------------------------------------------
export function TeamCatchSheet({ state, onClose, onRegistered }: {
  state: GameState;
  onClose: () => void;
  onRegistered: () => void;
}) {
  const team = state.team!;
  const { gameS } = useGame();
  const [grannies, setGrannies] = useState<CatchTarget[] | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { tagOf, avatarOf } = useFamilies();

  useEffect(() => {
    supabase.rpc("team_catch_targets").then(({ data }) => {
      const list = (data ?? []) as CatchTarget[];
      setGrannies(list);
      const own = list.find((g) => g.id === team.assigned_granny_id && !g.protected_until_s);
      if (own) setSelected(own.id);
    });
  }, [team.assigned_granny_id]);

  // Fredet eller allerede tatt av oss: kan ikke velges.
  const blocked = (g: CatchTarget) => g.taken_by_us || (g.protected_until_s != null && g.protected_until_s > gameS);
  const chosen = grannies?.find((g) => g.id === selected && !blocked(g));

  async function submit() {
    if (!selected) return;
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc("register_catch", { p_granny: selected });
    setBusy(false);
    if (error) return setError(friendly(error.message));
    onRegistered();
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Hvem har dere fanget?</h2>
      <p className="type-body-m text-text-secondary">
        Ta et bilde med grannyen og send det i lagets Telegram-gruppe. Registrer så fangsten her.
        Den teller når spilleder har godkjent den.
      </p>
      <p className="rounded-md bg-bg-info-subtle p-3 type-body-s">
        Bare deres egen granny blir tatt ut av jakten. Fanger dere en annen, får dere poeng én gang, og hun går fri igjen.
      </p>
      {grannies === null && <p className="type-body-m text-text-tertiary">Henter grannies …</p>}
      {grannies?.length === 0 && <p className="type-body-m text-text-secondary">Alle er fanget.</p>}
      {grannies?.map((g) => {
        const off = blocked(g);
        const who = g.id === team.assigned_granny_id ? "Deres granny" : g.is_romling ? "Rømlingen" : familyText(tagOf(g.id));
        const what = g.taken_by_us ? "dere har tatt henne"
          : g.protected_until_s != null && g.protected_until_s > gameS ? `fredet til ${formatGameTime(g.protected_until_s)}`
          : `${g.points}p${g.takes_out ? "" : " · går fri igjen"}`;
        return (
          <SelectRow
            key={g.id}
            title={g.name}
            subtitle={`${who} · ${what}`}
            lead={avatarOf(g.id) ? <Avatar name={g.name} url={avatarOf(g.id)} /> : <Initial name={g.name} />}
            selected={g.id === selected && !off}
            onClick={() => !off && setSelected(g.id)}
            trailing={off ? <Badge tone="neutral">{g.taken_by_us ? "Tatt" : "Fredet"}</Badge> : <Badge tone="success">Fri</Badge>}
          />
        );
      })}
      {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
      <Button icon="target" block disabled={!chosen || busy} onClick={submit}>
        {chosen ? `Registrer fangst av ${chosen.name}` : "Velg hvem dere fanget"}
      </Button>
    </Sheet>
  );
}

// Status etter registrering, vises over «Fang granny»-knappen.
export function TeamCatchStatus({ refreshKey }: { refreshKey: number }) {
  const [catches, setCatches] = useState<TeamCatch[]>([]);
  const load = useCallback(async () => {
    const { data } = await supabase.rpc("team_catches");
    if (data) setCatches(data as TeamCatch[]);
  }, []);
  useInterval(load, 4000);
  useEffect(() => { load(); }, [refreshKey, load]);

  const c = catches.find((x) => x.age_s < 300);
  if (!c) return null;

  let tone = "bg-bg-surface", icon: "clock" | "check" | "x" | "alert" = "clock", title = "", text = "";
  if (c.status === "pending") {
    title = `${c.granny_name}: venter på spilleder`;
    text = c.takes_out ? "Husk å sende bildet i lagets Telegram-gruppe."
      : "Send bildet i Telegram-gruppa. Hun går fri igjen når fangsten er godkjent.";
  } else if (c.status === "confirmed" && c.released) {
    tone = "bg-bg-success-subtle"; icon = "check";
    title = `Godkjent! Dere fikk poeng for ${c.granny_name}`;
    text = c.protected_until_s != null ? `Hun går fri igjen og er fredet til ${formatGameTime(c.protected_until_s)}.` : "Hun går fri igjen.";
  } else if (c.status === "confirmed") {
    tone = "bg-bg-success-subtle"; icon = "check";
    title = `${c.granny_name} er fanget!`;
    text = `Registrert ${formatGameTime(c.registered_s)}.`;
  } else if (c.status === "void") {
    tone = "bg-bg-warning-subtle"; icon = "alert";
    title = `${c.granny_name} er tatt av et annet lag`;
    text = "Spilleder godkjente et annet lag.";
  } else if (c.admin_deciding) {
    tone = "bg-bg-warning-subtle"; icon = "alert";
    title = `${c.granny_name} sier nei`;
    text = "Spilleder avgjør.";
  } else {
    tone = "bg-bg-danger-subtle"; icon = "x";
    title = "Fangsten teller ikke";
    text = `Spilleder har avgjort at ${c.granny_name} går fri.`;
  }

  return (
    <div className={`flex w-full items-center gap-3 rounded-lg border-2 border-border-strong p-3 ${tone}`}>
      <Icon name={icon} size={24} />
      <div>
        <div className="type-label-m">{title}</div>
        <div className="type-body-s text-text-secondary">{text}</div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// G6 · Fanget
// ---------------------------------------------------------------------------
export function CaughtCard({ grannyId }: { grannyId: string }) {
  const [info, setInfo] = useState<{ catch_order: number | null; caught_at_s: number | null; team: string | null } | null>(null);
  useEffect(() => {
    supabase.from("grannies").select("catch_order, caught_at_s, teams:caught_by(name)").eq("id", grannyId).single()
      .then(({ data }) => {
        if (!data) return;
        const d = data as unknown as { catch_order: number | null; caught_at_s: number | null; teams: { name: string } | null };
        setInfo({ catch_order: d.catch_order, caught_at_s: d.caught_at_s, team: d.teams?.name ?? null });
      });
  }, [grannyId]);

  return (
    <div className="flex flex-col gap-2 rounded-xl border-2 border-border-strong bg-bg-surface p-5 shadow-hard">
      <div><Badge tone="danger">{info?.catch_order ? `Fanget som nr. ${info.catch_order}` : "Fanget"}</Badge></div>
      <h2 className="type-display-xl">Tatt!</h2>
      <p className="type-body-l text-text-secondary">
        {info?.team ? `${info.team} fanget deg ${info.caught_at_s != null ? formatGameTime(info.caught_at_s) : ""}. ` : ""}
        Du er ute av jakten, men poengene dine står.
      </p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// S1 · Spilleders fangstkø
// ---------------------------------------------------------------------------
export function AdminCatchQueue() {
  const [queue, setQueue] = useState<AdminCatch[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    const { data } = await supabase.rpc("admin_catch_queue");
    if (data) setQueue(data as AdminCatch[]);
  }, []);
  useInterval(load, 4000);

  async function resolve(id: string, accept: boolean) {
    setBusy(id);
    const { error } = await supabase.rpc("admin_resolve_catch", { p_catch: id, p_accept: accept });
    setBusy(null);
    setError(error ? friendly(error.message) : null);
    load();
  }

  if (queue.length === 0) return null;
  return (
    <section className="flex flex-col gap-2">
      <h2 className="flex items-center gap-2 type-heading-m">Fangster <Badge tone="danger">{String(queue.length)}</Badge></h2>
      {error && <p className="type-body-s text-text-danger">{error}</p>}
      {queue.map((c) => (
        <div key={c.id} className="flex flex-col gap-2 rounded-lg border-2 border-border-strong bg-bg-warning-subtle p-3">
          <div className="flex items-center justify-between gap-2">
            <Badge tone="warning">Venter på deg</Badge>
            <span className="type-timer-s text-text-tertiary">reg. {formatGameTime(c.registered_s)}</span>
          </div>
          <p className="flex items-center gap-2 type-label-m">
            <TeamDot color={c.team_color} /> {c.team_name} sier de har fanget {c.granny_name}{c.is_romling ? " (Rømlingen)" : ""}.
          </p>
          {!c.takes_out && (
            <p className="type-body-s text-text-secondary">Ikke deres granny: godkjent gir laget poeng, og hun går fri igjen.</p>
          )}
          {c.selfie_path
            ? <StoredPhoto path={c.selfie_path} className="max-h-64 w-full rounded-md object-contain" />
            : <p className="type-body-s text-text-tertiary">Se bildet i lagets Telegram-gruppe.</p>}
          {c.competing > 1 && <p className="type-body-s text-text-secondary">{c.competing} lag krever henne. Den som teller, gjør de andre ugyldige.</p>}
          <div className="flex gap-2">
            <Button size="M" icon="check" className="flex-1" disabled={busy === c.id} onClick={() => resolve(c.id, true)}>Fangst teller</Button>
            <Button size="M" variant="secondary" icon="x" disabled={busy === c.id} onClick={() => resolve(c.id, false)}>{c.takes_out ? "Går fri" : "Teller ikke"}</Button>
          </div>
        </div>
      ))}
    </section>
  );
}

function familyText(tag: GrannyTag | null) {
  if (!tag) return "Granny";
  return tag.kind === "family" ? `${tag.team.name} sin granny` : "★ Bonus-granny, ingen familie";
}
