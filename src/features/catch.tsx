// Fangst: L2 (lag registrerer), G5 (granny bekrefter), G6 (fanget), S1-kø.
import { useCallback, useEffect, useState } from "react";
import { supabase } from "../lib/supabase";
import { useInterval } from "../lib/hooks";
import { formatCountdown, formatGameTime } from "../lib/gameClock";
import type { AdminCatch, GameState, GrannyRow, PendingClaim, TeamCatch } from "../lib/types";
import { Badge, Button, Dialog, Initial, SelectRow, Sheet, TeamDot } from "../components/ui";
import { Icon } from "../components/Icon";

const CONFIRM_TIMEOUT_S = 120;

const ERRORS: Record<string, string> = {
  "Spillet er ikke i gang": "Spillet er ikke i gang. Vent til spilleder starter eller fortsetter.",
  "Jakten har ikke startet": "Jakten starter 0:15. Grannyene har fortsatt forsprang.",
  "Hun er allerede fanget": "Hun er allerede fanget.",
  "Krever lisens": "Rømlingen kan bare fanges med lisens fra Nattevakten.",
  "Kravet er ikke åpent lenger": "Det kravet er ikke åpent lenger. Spilleder har kanskje avgjort det.",
};
const friendly = (msg: string) => ERRORS[msg] ?? "Noe gikk galt. Prøv igjen.";

// ---------------------------------------------------------------------------
// L2 · Registrer fangst
// ---------------------------------------------------------------------------
export function TeamCatchSheet({ state, gameS, onClose, onRegistered }: {
  state: GameState;
  gameS: number;
  onClose: () => void;
  onRegistered: () => void;
}) {
  const team = state.team!;
  const [grannies, setGrannies] = useState<GrannyRow[] | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    supabase.from("grannies").select("id, name, is_romling, caught_at_s").then(({ data }) => {
      const free = ((data ?? []) as GrannyRow[]).filter((g) => g.caught_at_s == null);
      // Egen granny først, så alfabetisk, Rømlingen sist.
      free.sort((a, b) =>
        Number(b.id === team.assigned_granny_id) - Number(a.id === team.assigned_granny_id) ||
        Number(a.is_romling) - Number(b.is_romling) ||
        a.name.localeCompare(b.name, "nb"));
      setGrannies(free);
      if (free[0]?.id === team.assigned_granny_id) setSelected(free[0].id);
    });
  }, [team.assigned_granny_id]);

  const points = (g: GrannyRow) => (g.is_romling ? 20 : g.id === team.assigned_granny_id ? 15 : 10);
  const chosen = grannies?.find((g) => g.id === selected);
  const romlingKnown = grannies?.some((g) => g.is_romling);
  const showLockedRomling = !team.has_license && gameS >= state.romling_reveal_s && !romlingKnown;

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
      <p className="type-body-m text-text-secondary">Hun må bekrefte før fangsten teller. Tidspunktet nå avgjør rekkefølgen.</p>
      {grannies === null && <p className="type-body-m text-text-tertiary">Henter grannies …</p>}
      {grannies?.length === 0 && <p className="type-body-m text-text-secondary">Alle er fanget.</p>}
      {grannies?.map((g) => (
        <SelectRow
          key={g.id}
          title={g.name}
          subtitle={`${g.id === team.assigned_granny_id ? "Deres granny · " : g.is_romling ? "Rømlingen · " : ""}${points(g)}p`}
          lead={<Initial name={g.name} />}
          selected={g.id === selected}
          onClick={() => setSelected(g.id)}
          trailing={<Badge tone="success">Fri</Badge>}
        />
      ))}
      {showLockedRomling && (
        <SelectRow
          title="Rømlingen"
          subtitle="20p · krever lisens fra Nattevakten"
          lead={<Initial name="?" muted />}
          disabled
          trailing={<Badge tone="neutral">Låst</Badge>}
        />
      )}
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
    const left = CONFIRM_TIMEOUT_S - c.age_s;
    title = `Venter på at ${c.granny_name} bekrefter`;
    text = left > 0 ? `Spilleder avgjør om ${formatCountdown(left)} hvis hun ikke svarer.` : "Hun har ikke svart. Spilleder avgjør.";
  } else if (c.status === "confirmed") {
    tone = "bg-bg-success-subtle"; icon = "check";
    title = `${c.granny_name} er fanget!`;
    text = `Registrert ${formatGameTime(c.registered_s)}.`;
  } else if (c.status === "void") {
    tone = "bg-bg-warning-subtle"; icon = "alert";
    title = `${c.granny_name} er tatt av et annet lag`;
    text = "Hun valgte et annet lag som fanget henne.";
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
// G5 · Bekreft fangst
// ---------------------------------------------------------------------------
export function GrannyCatchDialog({ onResolved }: { onResolved: () => void }) {
  const [claims, setClaims] = useState<PendingClaim[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [, tick] = useState(0);

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("granny_pending_catches");
    if (data) setClaims(data as PendingClaim[]);
  }, []);
  useInterval(load, 4000);
  useInterval(() => tick((n) => n + 1), 1000, claims.length > 0);

  if (claims.length === 0) return null;
  const single = claims.length === 1;
  const choice = single ? claims[0].id : selected;
  const oldest = Math.max(...claims.map((c) => c.age_s));
  const left = CONFIRM_TIMEOUT_S - oldest;

  async function respond(accept: boolean) {
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc("granny_respond_catch", { p_catch: accept ? choice : null, p_accept: accept });
    setBusy(false);
    if (error) {
      setError(friendly(error.message));
      load();
      return;
    }
    setClaims([]);
    onResolved();
  }

  return (
    <Dialog>
      <div className="flex items-center justify-between">
        <span className="grid size-12 place-items-center rounded-full bg-bg-danger text-icon-on-danger"><Icon name="target" /></span>
        <span className="type-timer-l text-text-danger">{left > 0 ? formatCountdown(left) : "0:00"}</span>
      </div>
      <h2 className="type-display-m">
        {single ? `${claims[0].team_name} sier de har fanget deg.` : `${claims.length} lag sier de har fanget deg.`}
      </h2>
      <p className="type-body-m text-text-secondary">
        {single
          ? "Stemmer det? Fangsten teller først når du bekrefter. Svarer du ikke, avgjør spilleder."
          : "Hvem tok deg først? Velg laget. Svarer du ikke, avgjør spilleder."}
      </p>
      {!single && claims.map((c) => (
        <SelectRow
          key={c.id}
          title={c.team_name}
          subtitle={`Registrert ${formatGameTime(c.registered_s)}`}
          lead={<TeamDot color={c.team_color} size={20} />}
          selected={c.id === selected}
          onClick={() => setSelected(c.id)}
        />
      ))}
      {error && <p className="type-body-s text-text-danger">{error}</p>}
      <Button variant="danger" icon="check" block disabled={!choice || busy} onClick={() => respond(true)}>
        {single ? "Ja, jeg er tatt" : selected ? `${claims.find((c) => c.id === selected)?.team_name} tok meg` : "Velg laget som tok deg"}
      </Button>
      <Button variant="secondary" block disabled={busy} onClick={() => respond(false)}>
        {single ? "Nei, de bommet" : "Nei, ingen tok meg"}
      </Button>
    </Dialog>
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
        <div key={c.id} className={`flex flex-col gap-2 rounded-lg border-2 border-border-strong p-3 ${c.status === "rejected" || c.overdue ? "bg-bg-warning-subtle" : "bg-bg-app"}`}>
          <div className="flex items-center justify-between gap-2">
            <Badge tone={c.status === "rejected" ? "warning" : c.overdue ? "danger" : "neutral"}>
              {c.status === "rejected" ? "Granny sier nei" : c.overdue ? "Ikke bekreftet" : "Venter på granny"}
            </Badge>
            <span className="type-timer-s text-text-tertiary">reg. {formatGameTime(c.registered_s)}</span>
          </div>
          <p className="flex items-center gap-2 type-label-m">
            <TeamDot color={c.team_color} /> {c.team_name} sier de har fanget {c.granny_name}{c.is_romling ? " (Rømlingen)" : ""}.
          </p>
          {c.competing > 1 && <p className="type-body-s text-text-secondary">{c.competing} lag krever henne. Den som teller, gjør de andre ugyldige.</p>}
          <div className="flex gap-2">
            <Button size="M" icon="check" className="flex-1" disabled={busy === c.id} onClick={() => resolve(c.id, true)}>Fangst teller</Button>
            <Button size="M" variant="secondary" icon="x" disabled={busy === c.id} onClick={() => resolve(c.id, false)}>Går fri</Button>
          </div>
        </div>
      ))}
    </section>
  );
}
