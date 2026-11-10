// S1 · Spilleder – live-kontroll (forenklet)
import { useCallback, useMemo, useState } from "react";
import { supabase } from "../lib/supabase";
import { useGame } from "../lib/game";
import { useInterval } from "../lib/hooks";
import { useZones } from "../lib/useZones";
import { GameMap, zoneMarkers } from "../map/GameMap";
import { Badge, Button, TeamDot } from "../components/ui";
import { LogoLockup } from "../components/Logo";
import { formatClock, formatCountdown } from "../lib/gameClock";
import type { AdminLive as AdminLiveData, MapMarker, TelegramStats } from "../lib/types";

const STALE_S = 60;

function ageText(age: number | null) {
  if (age == null) return "aldri";
  return age < 90 ? `${age} s` : `${Math.round(age / 60)} min`;
}

export function AdminLive() {
  const { state, gameS, refresh } = useGame();
  const zones = useZones();
  const [live, setLive] = useState<AdminLiveData | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("admin_live");
    if (!error) setLive(data as AdminLiveData);
  }, []);
  useInterval(load, 5000);

  const [stats, setStats] = useState<TelegramStats | null>(null);
  const [windowMin, setWindowMin] = useState(30);
  const loadStats = useCallback(async () => {
    const { data, error } = await supabase.rpc("admin_telegram_stats", { p_window_min: windowMin });
    if (!error) setStats(data as TelegramStats);
  }, [windowMin]);
  useInterval(loadStats, 15_000);

  async function setStatus(action: "start" | "pause" | "resume" | "end") {
    if (action === "end" && !confirm("Avslutte spillet nå? Det kan ikke angres.")) return;
    setBusy(true);
    const { error } = await supabase.rpc("admin_set_status", { p_action: action });
    setBusy(false);
    setError(error?.message ?? null);
    refresh();
  }

  const markers = useMemo<MapMarker[]>(() => {
    const list = zoneMarkers(zones);
    for (const g of live?.grannies ?? []) {
      if (g.lat == null || g.lng == null || g.caught_at_s != null) continue;
      list.push({
        key: g.id,
        kind: g.live_reason ? "live" : g.is_romling ? "romling" : "granny",
        lat: g.lat, lng: g.lng,
        label: `${g.name}${g.is_romling ? " (Rømling)" : ""} · ${ageText(g.age_s)}`,
      });
    }
    for (const t of live?.teams ?? []) {
      if (t.lat == null || t.lng == null) continue;
      list.push({ key: t.id, kind: "team", color: t.color, lat: t.lat, lng: t.lng, label: t.name });
    }
    return list;
  }, [zones, live]);

  const stale = state.status === "running"
    ? (live?.grannies ?? []).filter((g) => g.caught_at_s == null && (g.age_s == null || g.age_s > STALE_S))
    : [];

  return (
    <div className="flex h-dvh flex-col bg-bg-app lg:flex-row">
      <aside className="flex flex-col gap-4 overflow-y-auto border-border-strong bg-bg-surface p-5 lg:w-[380px] lg:border-r-2">
        <LogoLockup scale={0.6} />
        <section className="rounded-lg border-2 border-border-strong bg-bg-brand-subtle p-4 shadow-hard">
          <div className="flex items-center justify-between">
            <span className="type-label-caps text-text-secondary">Spilletid</span>
            <Badge tone={state.status === "running" ? "success" : state.status === "paused" ? "warning" : "neutral"}>
              {{ setup: "Oppsett", running: "Pågår", paused: "Pause", ended: "Slutt" }[state.status]}
            </Badge>
          </div>
          <div className="type-timer-xl">{formatClock(gameS)}</div>
          <div className="type-body-s text-text-secondary">
            {state.next_ping_s != null ? `Neste ping om ${formatCountdown(state.next_ping_s - gameS)}` : "Ingen flere ping"}
          </div>
          <div className="mt-3 flex gap-2">
            {state.status === "setup" && <Button size="M" icon="play" block disabled={busy} onClick={() => setStatus("start")}>Start spillet</Button>}
            {state.status === "running" && <Button size="M" variant="secondary" icon="pause" className="flex-1" disabled={busy} onClick={() => setStatus("pause")}>Pause</Button>}
            {state.status === "paused" && <Button size="M" icon="play" className="flex-1" disabled={busy} onClick={() => setStatus("resume")}>Fortsett</Button>}
            {(state.status === "running" || state.status === "paused") && <Button size="M" variant="danger" disabled={busy} onClick={() => setStatus("end")}>Avslutt</Button>}
          </div>
          {error && <p className="mt-2 type-body-s text-text-danger">{error}</p>}
        </section>

        {stale.length > 0 && (
          <section className="rounded-lg border-2 border-border-strong bg-bg-warning-subtle p-3">
            <Badge tone="warning">Posisjon</Badge>
            <p className="mt-2 type-label-m">
              {stale.map((g) => g.name).join(", ")}: ingen posisjon på over {STALE_S} sek.
            </p>
          </section>
        )}

        <TelegramStatsPanel stats={stats} windowMin={windowMin} onWindow={setWindowMin} />

        <section>
          <h2 className="mb-2 type-heading-m">Grannies</h2>
          <ul className="flex flex-col gap-1">
            {(live?.grannies ?? []).map((g) => (
              <li key={g.id} className="flex items-center gap-2 rounded-md px-2 py-1 type-body-s">
                <span className="flex-1 type-label-s">{g.name}{g.is_romling ? " (Rømling)" : ""}</span>
                {g.caught_at_s != null ? <Badge tone="danger">Fanget</Badge>
                  : !g.telegram_linked ? <Badge tone="warning">Ikke koblet</Badge>
                  : <span className={`type-timer-s ${g.age_s == null || g.age_s > STALE_S ? "text-text-warning" : "text-text-tertiary"}`}>{ageText(g.age_s)}</span>}
              </li>
            ))}
          </ul>
        </section>

        <section>
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
      </aside>
      <main className="relative min-h-[50vh] flex-1">
        <GameMap zones={zones} markers={markers} />
      </main>
    </div>
  );
}

// Felttest: hvor ofte og hvor presist kommer Telegram-posisjonene?
function secs(v: number | null) {
  if (v == null) return "–";
  return v < 90 ? `${Math.round(v)} s` : `${Math.round(v / 60)} min`;
}

function TelegramStatsPanel({
  stats,
  windowMin,
  onWindow,
}: {
  stats: TelegramStats | null;
  windowMin: number;
  onWindow: (m: number) => void;
}) {
  return (
    <section className="rounded-lg border border-border-default bg-bg-surface p-3">
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
