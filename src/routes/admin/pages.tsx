// Spilleders sider uten kart: Oppdrag, Taxi, Poeng, Meldinger og Deltakere.
import { useCallback, useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";
import { useGame } from "../../lib/game";
import { useInterval } from "../../lib/hooks";
import { useEventVersion } from "../../lib/events";
import { tagText, useFamilies } from "../../lib/families";
import { formatGameTime } from "../../lib/gameClock";
import { friendly } from "../../lib/errors";
import { Badge, TeamDot } from "../../components/ui";
import { AdminEventLog, AdminTools } from "../../features/admin";
import { AdminQuestQueue, AdminQuests } from "../../features/quests";
import { AdminTaxis } from "../../features/taxis";
import { AdminTelegramAlerts } from "../../components/TelegramAlerts";
import { ageText, STALE_S } from "../AdminLive";
import { AdminPage, useAdminLive } from "./AdminShell";
import type { Summary as SummaryData, TelegramStats } from "../../lib/types";

const card = "rounded-lg border border-border-default bg-bg-surface p-3";

// ---------------------------------------------------------------------------
// Oppdrag
// ---------------------------------------------------------------------------
export function AdminQuestsPage() {
  const { live } = useAdminLive();
  return (
    <AdminPage title="Oppdrag" intro="Send side quests til lag eller grannyer. De sender beviset i Telegram og markerer som levert. Du godkjenner her.">
      <AdminQuestQueue />
      <AdminQuests live={live} />
    </AdminPage>
  );
}

// ---------------------------------------------------------------------------
// Taxi
// ---------------------------------------------------------------------------
export function AdminTaxiPage() {
  const { live } = useAdminLive();
  const { gameS } = useGame();
  const taxis = live?.taxis ?? [];
  return (
    <AdminPage title="Taxi" intro="Turer som pågår, og hvor mange turer hver granny har brukt.">
      {taxis.length === 0 && <p className={`${card} type-body-m text-text-secondary`}>Ingen taxier. Legg dem inn under Oppsett → Taxier.</p>}
      <AdminTaxis taxiCount={taxis.length} gameS={gameS} />
      {taxis.length > 0 && (
        <section className={card}>
          <h2 className="mb-2 type-heading-m">Taxiene</h2>
          <ul className="flex flex-col gap-1">
            {taxis.map((x) => (
              <li key={x.id} className="flex items-center gap-2 px-2 py-1 type-body-s">
                <span className="flex-1 type-label-s">{x.name}</span>
                {x.ride ? <Badge tone="warning">{x.ride.status === "accepted" ? "Henter" : "Kjører"} {x.ride.granny_name}</Badge> : <span className="text-text-tertiary">ledig</span>}
                <span className="type-timer-s text-text-tertiary" title="Siste posisjon">{ageText(x.age_s)}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </AdminPage>
  );
}

// ---------------------------------------------------------------------------
// Poeng: poengtavlen er bare for spilleder
// ---------------------------------------------------------------------------
export function AdminPointsPage() {
  const { live } = useAdminLive();
  const { version } = useEventVersion();
  const { tagOf } = useFamilies();
  const [data, setData] = useState<SummaryData | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("game_summary");
    if (error) setError(friendly(error));
    else { setError(null); setData(data as SummaryData); }
  }, []);
  useInterval(load, 10_000);
  // Hent på nytt når noe skjer i spillet (fangst, godkjent oppdrag …).
  useEffect(() => { if (version) load(); }, [version, load]);

  const ended = data?.status === "ended";
  const places = data?.granny_place_points ?? [];

  return (
    <AdminPage title="Poeng" intro="Bare spilleder ser poengtavlen. Lag og grannyer ser bare sine egne poeng.">
      {error && <p className="rounded-md bg-bg-warning-subtle p-3 type-body-m">{error}</p>}
      {data && !ended && <div><Badge tone="warning">Foreløpig – spillet er ikke over</Badge></div>}

      {data && (
        <>
          <section className="flex flex-col gap-2">
            <h2 className="type-heading-l">Letelagene</h2>
            <ol className="flex flex-col gap-1 rounded-lg border-2 border-border-strong bg-bg-surface p-2">
              {data.teams.map((t, i) => (
                <li key={t.id} className="flex items-center gap-3 rounded-md px-3 py-2">
                  <span className="w-6 type-timer-m">{i + 1}</span>
                  <TeamDot color={t.color} />
                  <span className="flex-1 type-label-l">{t.name}</span>
                  <span className="type-body-s text-text-secondary">{t.catches} fangst{t.catches === 1 ? "" : "er"}</span>
                  <span className="w-14 text-right type-timer-m">{t.points}p</span>
                </li>
              ))}
            </ol>
          </section>

          <section className="flex flex-col gap-2">
            <h2 className="type-heading-l">Grannyene</h2>
            <ol className="flex flex-col gap-1 rounded-lg border-2 border-border-strong bg-bg-surface p-2">
              {data.grannies.map((g, i) => (
                <li key={g.id} className="flex items-center gap-3 rounded-md px-3 py-2">
                  <span className="w-6 type-timer-m">{i + 1}</span>
                  <span className="flex-1">
                    <span className="block type-label-l">{g.name} <span className="type-body-s text-text-secondary">{tagText(tagOf(g.id))}</span></span>
                    <span className="block type-body-s text-text-secondary">
                      {g.catch_order ? `Fanget som nr. ${g.catch_order} av ${g.caught_by} (${formatGameTime(g.caught_at_s!)})` : ended ? "Aldri fanget" : "Fri"}
                      {` · ${g.place}. plass: ${g.placement}p + ${g.tasks}p oppdrag`}
                    </span>
                  </span>
                  <span className="w-14 text-right type-timer-m">{g.total}p</span>
                </li>
              ))}
            </ol>
            <p className="type-body-s text-text-tertiary">
              Plassering: den som fanges først, får siste plass. Alle som er fri, deler 1. plass.
              Poeng per plass: {places.length ? places.map((p, i) => `${i + 1}. ${p}p`).join(" · ") : "ingen"} (endres under Oppsett → Spillet).
            </p>
          </section>
        </>
      )}

      <AdminTools live={live} only="points" />

      {data && (
        <section className={`${card} flex flex-col gap-2`}>
          <h2 className="type-heading-m">Fangstene</h2>
          <ul className="flex flex-col gap-1">
            {data.catches.map((c) => (
              <li key={`${c.granny}-${c.at_s}`} className="type-body-m">
                <span className="type-timer-s text-text-tertiary">{formatGameTime(c.at_s)}</span> {c.order ? `${c.order}. ` : ""}{c.granny} – {c.team}
              </li>
            ))}
            {data.catches.length === 0 && <li className="type-body-m text-text-secondary">Ingen fangster.</li>}
          </ul>
          <h2 className="type-heading-m">Sladringer</h2>
          {data.snitches.length === 0 ? <p className="type-body-m text-text-secondary">Ingen har sladret.</p> : (
            <ul className="flex flex-col gap-1">
              {data.snitches.map((s) => (
                <li key={`${s.snitch}-${s.at_s}`} className="type-body-m">
                  <span className="type-timer-s text-text-tertiary">{formatGameTime(s.at_s)}</span> {s.snitch} sladret på {s.target}.
                </li>
              ))}
            </ul>
          )}
        </section>
      )}
    </AdminPage>
  );
}

// ---------------------------------------------------------------------------
// Meldinger
// ---------------------------------------------------------------------------
export function AdminMessagesPage() {
  const { live } = useAdminLive();
  return (
    <AdminPage title="Meldinger" intro="Send varsel til alle, til lagene, til grannyene eller til én bestemt. Varselet kommer i appen, som push og i Telegram.">
      <AdminTools live={live} only="broadcast" />
      <div className={card}><AdminEventLog /></div>
    </AdminPage>
  );
}

// ---------------------------------------------------------------------------
// Deltakere
// ---------------------------------------------------------------------------
export function AdminPeoplePage() {
  const { live } = useAdminLive();
  const { tagOf } = useFamilies();
  const [stats, setStats] = useState<TelegramStats | null>(null);
  const [windowMin, setWindowMin] = useState(30);
  const loadStats = useCallback(async () => {
    const { data, error } = await supabase.rpc("admin_telegram_stats", { p_window_min: windowMin });
    if (!error) setStats(data as TelegramStats);
  }, [windowMin]);
  useInterval(loadStats, 15_000);

  return (
    <AdminPage title="Deltakere" intro="Hvem som er pålogget, hvem som deler posisjon, og hvem som får varsler i Telegram.">
      <section className={card}>
        <h2 className="mb-2 type-heading-m">Grannies</h2>
        <ul className="flex flex-col gap-1">
          {(live?.grannies ?? []).map((g) => (
            <li key={g.id} className="flex items-center gap-2 rounded-md px-2 py-1 type-body-s">
              <span className="flex-1 type-label-s">
                {g.name} <span className="font-normal text-text-secondary">{tagText(tagOf(g.id))}</span>
              </span>
              {g.caught_at_s != null ? <Badge tone="danger">Fanget</Badge>
                : !g.telegram_linked ? <Badge tone="warning">Ikke koblet til Telegram</Badge>
                : <span className={`type-timer-s ${g.age_s == null || g.age_s > STALE_S ? "text-text-warning" : "text-text-tertiary"}`} title="Siste posisjon">{ageText(g.age_s)}</span>}
            </li>
          ))}
        </ul>
      </section>

      <section className={card}>
        <h2 className="mb-2 type-heading-m">Lag</h2>
        <ul className="flex flex-col gap-1">
          {(live?.teams ?? []).map((t) => (
            <li key={t.id} className="flex items-center gap-2 px-2 py-1">
              <TeamDot color={t.color} />
              <span className="flex-1 type-label-s">{t.name}</span>
              <span className="type-timer-s text-text-tertiary">{t.phones} tlf</span>
            </li>
          ))}
        </ul>
      </section>

      <section className={card}>
        <h2 className="mb-2 type-heading-m">Taxier</h2>
        <ul className="flex flex-col gap-1">
          {(live?.taxis ?? []).map((x) => (
            <li key={x.id} className="flex items-center gap-2 px-2 py-1 type-body-s">
              <span className="flex-1 type-label-s">{x.name}</span>
              <span className="type-timer-s text-text-tertiary">{x.phones} tlf · posisjon {ageText(x.age_s)}</span>
            </li>
          ))}
          {(live?.taxis.length ?? 0) === 0 && <li className="px-2 type-body-s text-text-tertiary">Ingen taxier.</li>}
        </ul>
      </section>

      <AdminTelegramAlerts />
      <TelegramStatsPanel stats={stats} windowMin={windowMin} onWindow={setWindowMin} />
    </AdminPage>
  );
}

// Felttest: hvor ofte og hvor presist kommer Telegram-posisjonene?
function secs(v: number | null) {
  if (v == null) return "–";
  return v < 90 ? `${Math.round(v)} s` : `${Math.round(v / 60)} min`;
}

function TelegramStatsPanel({ stats, windowMin, onWindow }: {
  stats: TelegramStats | null;
  windowMin: number;
  onWindow: (m: number) => void;
}) {
  return (
    <section className={card}>
      <div className="mb-2 flex items-center justify-between gap-2">
        <h2 className="type-heading-m">Telegram-måling</h2>
        <select
          value={windowMin}
          onChange={(e) => onWindow(Number(e.target.value))}
          className="rounded-sm border border-border-default bg-bg-surface px-2 py-1 type-label-s"
        >
          {[10, 30, 60, 150].map((m) => (
            <option key={m} value={m}>Siste {m} min</option>
          ))}
        </select>
      </div>
      <table className="w-full type-body-s">
        <thead className="text-left text-text-tertiary">
          <tr>
            <th className="font-semibold">Granny</th>
            <th className="whitespace-nowrap pl-2 text-right font-semibold" title="Antall oppdateringer">Ant.</th>
            <th className="whitespace-nowrap pl-2 text-right font-semibold" title="Typisk tid mellom oppdateringer">Median</th>
            <th className="whitespace-nowrap pl-2 text-right font-semibold" title="9 av 10 hull er kortere enn dette">P90</th>
            <th className="whitespace-nowrap pl-2 text-right font-semibold" title="Største hull">Maks</th>
            <th className="whitespace-nowrap pl-2 text-right font-semibold" title="Typisk nøyaktighet fra Telegram">±m</th>
          </tr>
        </thead>
        <tbody className="type-timer-s">
          {(stats?.grannies ?? []).map((g) => (
            <tr key={g.id} className="border-t border-border-default">
              <td className="py-1 font-sans">
                {g.name}
                {!g.linked && <span className="text-text-warning"> · ikke koblet</span>}
                {g.linked && g.updates > 0 && !g.live && <span className="text-text-danger"> · ikke live</span>}
              </td>
              <td className="whitespace-nowrap pl-2 text-right">{g.updates}</td>
              <td className="whitespace-nowrap pl-2 text-right">{secs(g.median_gap_s)}</td>
              <td className="whitespace-nowrap pl-2 text-right">{secs(g.p90_gap_s)}</td>
              <td className={`whitespace-nowrap pl-2 text-right ${g.max_gap_s != null && g.max_gap_s > 180 ? "text-text-danger" : ""}`}>{secs(g.max_gap_s)}</td>
              <td className="whitespace-nowrap pl-2 text-right">{g.median_accuracy_m != null ? Math.round(g.median_accuracy_m) : "–"}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="mt-2 type-body-s text-text-tertiary">Hull over 3 min er røde. Tidene er fra Telegram, ikke fra serveren.</p>
    </section>
  );
}
