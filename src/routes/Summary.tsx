// Oppsummering etter spillet. Alle anonyme handlinger avsløres.
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { useGame, homeFor } from "../lib/game";
import { friendly } from "../lib/errors";
import { tagText, useFamilies } from "../lib/families";
import { formatGameTime } from "../lib/gameClock";
import type { Summary as SummaryData } from "../lib/types";
import { Badge, TeamDot } from "../components/ui";
import { Icon } from "../components/Icon";
import { LogoLockup } from "../components/Logo";

export function Summary() {
  const { state } = useGame();
  const [data, setData] = useState<SummaryData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const { tagOf } = useFamilies();

  useEffect(() => {
    supabase.rpc("game_summary").then(({ data, error }) => {
      if (error) setError(friendly(error));
      else setData(data as SummaryData);
    });
  }, [state.status]);

  const teamTie = data && data.teams.length > 1 && data.teams[0].points === data.teams[1].points && data.teams[0].catches === data.teams[1].catches;

  return (
    <div className="min-h-dvh bg-bg-app">
      <div className="mx-auto flex max-w-2xl flex-col gap-6 px-4 pt-[max(24px,env(safe-area-inset-top))] pb-10">
        <div className="flex items-center justify-between">
          <Link to={homeFor(state.role)} className="flex items-center gap-1 type-label-m text-text-brand"><Icon name="chevron-left" size={20} /> Tilbake</Link>
          {data && data.status !== "ended" && <Badge tone="warning">Foreløpig – bare spilleder ser dette</Badge>}
        </div>
        <LogoLockup scale={0.7} />
        <h1 className="type-display-l">{data?.game_name ?? "Oppsummering"}</h1>
        {error && <p className="rounded-md bg-bg-warning-subtle p-3 type-body-m">{error}</p>}

        {data && (
          <>
            <section className="flex flex-col gap-2">
              <h2 className="type-heading-l">Letelagene</h2>
              <ol className="flex flex-col gap-1 rounded-lg border-2 border-border-strong bg-bg-surface p-2">
                {data.teams.map((t, i) => (
                  <li key={t.id} className={`flex items-center gap-3 rounded-md px-3 py-2 ${state.team?.id === t.id ? "bg-bg-brand-subtle" : ""}`}>
                    <span className="w-6 type-timer-m">{i + 1}</span>
                    <TeamDot color={t.color} />
                    <span className="flex-1 type-label-l">{t.name}</span>
                    <span className="type-body-s text-text-secondary">{t.catches} fangst{t.catches === 1 ? "" : "er"}</span>
                    <span className="w-14 text-right type-timer-m">{t.points}p</span>
                  </li>
                ))}
              </ol>
              {teamTie && <p className="type-body-s text-text-secondary">Likt på poeng og fangster. Avgjør med stein, saks, papir!</p>}
            </section>

            <section className="flex flex-col gap-2">
              <h2 className="type-heading-l">Grannyene</h2>
              <ol className="flex flex-col gap-1 rounded-lg border-2 border-border-strong bg-bg-surface p-2">
                {data.grannies.map((g, i) => (
                  <li key={g.id} className={`flex items-center gap-3 rounded-md px-3 py-2 ${state.granny?.id === g.id ? "bg-bg-brand-subtle" : ""}`}>
                    <span className="w-6 type-timer-m">{i + 1}</span>
                    <span className="flex-1">
                      <span className="block type-label-l">{g.name} <span className="type-body-s text-text-secondary">{tagText(tagOf(g.id))}</span></span>
                      <span className="block type-body-s text-text-secondary">
                        {g.catch_order ? `Fanget som nr. ${g.catch_order} av ${g.caught_by} (${formatGameTime(g.caught_at_s!)})` : "Aldri fanget"}
                        {` · ${g.placement}p + ${g.tasks}p oppgaver`}
                      </span>
                    </span>
                    <span className="w-14 text-right type-timer-m">{g.total}p</span>
                  </li>
                ))}
              </ol>
              <p className="type-body-s text-text-tertiary">Likt? Den som ble fanget sist, vinner.</p>
            </section>

            {data.romling && (
              <section className="flex flex-col gap-1 rounded-lg border-2 border-border-strong bg-bg-inverse p-4 text-text-inverse">
                <span className="type-label-caps">Rømlingen</span>
                <span className="type-display-m">{data.romling.name}</span>
                <span className="type-body-m">
                  {data.romling.caught_by ? `Fanget av ${data.romling.caught_by} ${formatGameTime(data.romling.caught_at_s!)}.` : "Ble aldri fanget."}
                  {data.romling.licensed.length > 0 && ` Knekte koden: ${data.romling.licensed.map((l) => `${l.team} (${formatGameTime(l.at_s)})`).join(", ")}.`}
                </span>
              </section>
            )}

            <section className="flex flex-col gap-2">
              <h2 className="type-heading-l">Avslørt</h2>
              <h3 className="type-heading-s">Sladrehanken</h3>
              {data.snitches.length === 0 ? <p className="type-body-m text-text-secondary">Ingen sladret.</p> : (
                <ul className="flex flex-col gap-1">
                  {data.snitches.map((s) => (
                    <li key={`${s.snitch}-${s.at_s}`} className="type-body-m">
                      <span className="type-timer-s text-text-tertiary">{formatGameTime(s.at_s)}</span> {s.snitch} sladret på {s.target}{s.bonus ? " – og fikk 3p" : ""}.
                    </li>
                  ))}
                </ul>
              )}
              <h3 className="type-heading-s">Fotoalbumet</h3>
              {data.album.length === 0 ? <p className="type-body-m text-text-secondary">Ingen bilder ble godkjent.</p> : (
                <ul className="flex flex-col gap-1">
                  {data.album.map((a) => (
                    <li key={`${a.photographer}-${a.at_s}`} className="type-body-m">
                      <span className="type-timer-s text-text-tertiary">{formatGameTime(a.at_s)}</span> {a.photographer} tok bilde av {a.team}.
                    </li>
                  ))}
                </ul>
              )}
              <h3 className="type-heading-s">Fangstene</h3>
              <ul className="flex flex-col gap-1">
                {data.catches.map((c) => (
                  <li key={`${c.granny}-${c.at_s}`} className="type-body-m">
                    <span className="type-timer-s text-text-tertiary">{formatGameTime(c.at_s)}</span> {c.order ? `${c.order}. ` : ""}{c.granny}{c.is_romling ? " (Rømlingen)" : ""} – {c.team}
                  </li>
                ))}
                {data.catches.length === 0 && <li className="type-body-m text-text-secondary">Ingen fangster.</li>}
              </ul>
            </section>
          </>
        )}
      </div>
    </div>
  );
}
