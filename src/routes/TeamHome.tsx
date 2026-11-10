// L1 · Kart (letelag), L7 · Blindet
import { useCallback, useMemo, useState } from "react";
import { supabase } from "../lib/supabase";
import { useGame } from "../lib/game";
import { useDevicePosition, useInterval, useOnPing, useWakeLock } from "../lib/hooks";
import { useZones } from "../lib/useZones";
import { GameMap, zoneMarkers } from "../map/GameMap";
import { Badge, Button, Screen, TeamDot, TopBar } from "../components/ui";
import { Icon } from "../components/Icon";
import { formatCountdown, formatGameTime } from "../lib/gameClock";
import type { MapMarker, TeamMap } from "../lib/types";

export function TeamHome() {
  const { state, gameS, refresh } = useGame();
  const team = state.team!;
  const zones = useZones();
  const { coords } = useDevicePosition(true);
  useWakeLock(state.status === "running");

  const [map, setMap] = useState<TeamMap | null>(null);
  const [pingFlash, setPingFlash] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("team_map");
    if (!error) setMap(data as TeamMap);
  }, []);
  // Live-markører (sladret, utenfor) endrer seg mellom pingene, så vi spør jevnlig.
  useInterval(load, 10_000);
  useOnPing(state.ping_schedule_s, gameS, () => {
    // Litt forsinkelse, så siste Telegram-posisjon før pinget rekker å komme inn.
    setTimeout(() => { load(); refresh(); }, 1500);
    setPingFlash(true);
    setTimeout(() => setPingFlash(false), 6000);
  });

  const blindUntil = map?.blind_until_s ?? team.blind_until_s;
  const blind = blindUntil != null && blindUntil > gameS;

  const markers = useMemo<MapMarker[]>(() => {
    if (blind) return [];
    const list = zoneMarkers(zones);
    for (const m of map?.markers ?? []) {
      const label = m.kind === "romling" ? "???" : m.live_reason ? `${m.name} · live` : m.name;
      list.push({ key: m.id ?? "romling", kind: m.kind, lat: m.lat, lng: m.lng, label });
    }
    if (coords) list.push({ key: "meg", kind: "meg", lat: coords.lat, lng: coords.lng, label: "Dere" });
    return list;
  }, [blind, zones, map, coords]);

  const free = map?.markers.filter((m) => m.kind !== "romling").length ?? 0;

  return (
    <Screen className={blind ? "theme-dark" : ""}>
      <TopBar gameS={gameS} nextPingS={state.next_ping_s} status={state.status} blindUntilS={blindUntil} />
      <main className="relative flex-1">
        {blind ? (
          <div className="flex h-full flex-col items-center justify-center gap-4 px-6 text-center">
            <span className="grid size-24 place-items-center rounded-full bg-bg-surface-raised"><Icon name="eye-off" size={40} /></span>
            <h1 className="type-display-xl">Dere er blinde.</h1>
            <p className="type-body-l text-text-secondary">Ingen kart, ping eller taxivarsler. Bruk øynene.</p>
            <div className="w-full rounded-lg border-2 border-border-strong bg-bg-surface p-4">
              <div className="type-label-caps">Kartet er tilbake om</div>
              <div className="type-timer-xl">{formatCountdown(blindUntil! - gameS)}</div>
            </div>
          </div>
        ) : (
          <GameMap zones={zones} markers={markers} />
        )}

        {!blind && pingFlash && map?.ping_s != null && (
          <div className="absolute inset-x-4 top-3 flex items-center gap-3 rounded-lg border-2 border-border-strong bg-bg-surface p-3 shadow-hard">
            <span className="grid size-10 place-items-center rounded-full bg-bg-brand-subtle text-icon-brand"><Icon name="ping" size={20} /></span>
            <div>
              <div className="type-label-m">Ping! Kartet er oppdatert.</div>
              <div className="type-body-s text-text-secondary">
                {free} grannies på kartet.{state.next_ping_s != null ? ` Neste ping ${formatGameTime(state.next_ping_s)}.` : ""}
              </div>
            </div>
          </div>
        )}

        <div className="absolute inset-x-4 bottom-5 flex flex-col items-start gap-3">
          <div className="flex items-center gap-2 rounded-full border-2 border-border-strong bg-bg-surface py-2 pr-3 pl-2">
            <TeamDot color={team.color} />
            <span className="type-label-m">{team.name}</span>
            {team.assigned_granny_name && <Badge tone="warning">Deres: {team.assigned_granny_name}</Badge>}
          </div>
          {/* Fangst kommer i neste steg */}
          <Button icon="target" block disabled>Fang granny</Button>
        </div>
      </main>
    </Screen>
  );
}
