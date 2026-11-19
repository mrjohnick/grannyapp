// Lagets evnesekk: evner vunnet i side quests. Hver evne brukes én gang.
// Grannyene får varsel når de blir pinget eller vist live.
import { useCallback, useEffect, useState } from "react";
import { supabase } from "../lib/supabase";
import { friendly } from "../lib/errors";
import { useEventVersion } from "../lib/events";
import { useFamilies, tagText } from "../lib/families";
import type { AbilityKind, GrannyRow, TeamQuests } from "../lib/types";
import { Badge, Button, Initial, SelectRow, Sheet } from "../components/ui";
import { Avatar } from "../components/Avatar";

export const ABILITY_TEXT: Record<AbilityKind, { title: string; text: (liveS: number) => string; target: boolean }> = {
  ping_one:   { title: "Ping én granny", text: () => "Se hvor én valgfri granny er akkurat nå.", target: true },
  ping_all:   { title: "Ping alle grannyer", text: () => "Se hvor alle grannyene er akkurat nå.", target: false },
  ping_bonus: { title: "Ping bonus-grannyene", text: () => "Se hvor alle bonus-grannyene er akkurat nå.", target: false },
  live:       { title: "Live på én granny", text: (s) => `Se én valgfri granny live i ${s} sekunder.`, target: true },
};
const ORDER: AbilityKind[] = ["ping_one", "ping_all", "ping_bonus", "live"];

/** Antall ubrukte evner, for merket på knappen. */
export function abilityCount(q: TeamQuests | null) {
  return q?.abilities ? ORDER.reduce((n, k) => n + (q.abilities?.[k] ?? 0), 0) : 0;
}

export function AbilitySheet({ onClose, onUsed }: { onClose: () => void; onUsed: (msg: string) => void }) {
  const { version } = useEventVersion();
  const { tagOf, avatarOf } = useFamilies();
  const [data, setData] = useState<TeamQuests | null>(null);
  const [grannies, setGrannies] = useState<GrannyRow[]>([]);
  const [picking, setPicking] = useState<AbilityKind | null>(null);
  const [target, setTarget] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("team_quests");
    if (data) setData(data as TeamQuests);
  }, []);
  useEffect(() => { load(); }, [load, version]);
  useEffect(() => {
    supabase.from("grannies").select("id, name, is_romling, caught_at_s").then(({ data }) => {
      const rows = (data ?? []) as GrannyRow[];
      setGrannies(rows.filter((g) => !g.is_romling && g.caught_at_s == null).sort((a, b) => a.name.localeCompare(b.name, "nb")));
    });
  }, [version]);

  async function use(kind: AbilityKind, granny: string | null) {
    const name = grannies.find((g) => g.id === granny)?.name;
    if (!confirm(`Bruke «${ABILITY_TEXT[kind].title}»${name ? ` på ${name}` : ""}? Evnen kan bare brukes én gang.`)) return;
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc("use_team_ability", { p_kind: kind, p_granny: granny });
    setBusy(false);
    if (error) return setError(friendly(error) ?? "Noe gikk galt.");
    setPicking(null);
    setTarget(null);
    onUsed(kind === "live" ? `Dere ser ${name} live nå.` : "Pinget! Se kartet.");
  }

  const liveS = data?.ability_live_s ?? 30;
  const total = abilityCount(data);

  if (picking) {
    const info = ABILITY_TEXT[picking];
    return (
      <Sheet onClose={() => setPicking(null)}>
        <h2 className="type-display-m">{info.title}</h2>
        <p className="type-body-m text-text-secondary">Velg hvem. Hun får beskjed om det.</p>
        {grannies.map((g) => (
          <SelectRow key={g.id} title={g.name} subtitle={tagText(tagOf(g.id)) ?? undefined}
            lead={avatarOf(g.id) ? <Avatar name={g.name} url={avatarOf(g.id)} /> : <Initial name={g.name} />}
            selected={g.id === target} onClick={() => setTarget(g.id)} />
        ))}
        {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
        <Button block disabled={!target || busy} onClick={() => use(picking, target)}>
          {target ? `${info.title}: ${grannies.find((g) => g.id === target)?.name}` : "Velg en granny"}
        </Button>
      </Sheet>
    );
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Evner</h2>
      <p className="type-body-s text-text-secondary">
        Evner vinner dere i side quests. Spar dem til dere trenger dem. Hver evne kan brukes én gang, og bare dere ser resultatet.
      </p>
      {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
      {data === null && <p className="type-body-m text-text-tertiary">Henter evner …</p>}
      {data && total === 0 && <p className="type-body-m text-text-secondary">Sekken er tom. Løs side quests for å vinne evner.</p>}
      {data && ORDER.map((k) => {
        const n = data.abilities?.[k] ?? 0;
        const info = ABILITY_TEXT[k];
        return (
          <div key={k} className={`flex items-center gap-3 rounded-lg border-2 p-3 ${n > 0 ? "border-border-strong" : "border-border-default opacity-50"}`}>
            <div className="flex-1">
              <div className="type-label-l">{info.title}</div>
              <div className="type-body-s text-text-secondary">{info.text(liveS)}</div>
            </div>
            <Badge tone={n > 0 ? "brand" : "neutral"}>{`× ${n}`}</Badge>
            <Button size="M" disabled={n === 0 || busy} onClick={() => (info.target ? setPicking(k) : use(k, null))}>Bruk</Button>
          </div>
        );
      })}
    </Sheet>
  );
}
