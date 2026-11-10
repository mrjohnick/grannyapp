// G1 · Kart (granny)
import { useCallback, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { useGame } from "../lib/game";
import { useDevicePosition, useInterval, useWakeLock } from "../lib/hooks";
import { useZones } from "../lib/useZones";
import { GameMap, zoneMarkers } from "../map/GameMap";
import { Badge, Button, Screen, TopBar } from "../components/ui";
import { Icon } from "../components/Icon";
import type { MapMarker } from "../lib/types";
import { CaughtCard, GrannyCatchDialog } from "../features/catch";

export function GrannyHome() {
  const { state, gameS, refresh } = useGame();
  const granny = state.granny!;
  const zones = useZones();
  const { coords, error: gpsError } = useDevicePosition(!granny.caught);
  useWakeLock(state.status === "running");

  const [tgAge, setTgAge] = useState<number | null | undefined>(undefined);
  const loadTelegram = useCallback(async () => {
    const { data } = await supabase.rpc("my_telegram");
    if (data) setTgAge((data as { last_position_age_s: number | null }).last_position_age_s);
  }, []);
  useInterval(loadTelegram, 15_000);

  const markers = useMemo<MapMarker[]>(() => {
    const list = zoneMarkers(zones);
    if (coords) list.push({ key: "meg", kind: "meg", lat: coords.lat, lng: coords.lng, label: "Deg" });
    return list;
  }, [zones, coords]);

  const tgOk = tgAge != null && tgAge <= 60;

  return (
    <Screen>
      <TopBar gameS={gameS} nextPingS={state.next_ping_s} status={state.status} caught={granny.caught} />
      <main className="relative flex-1">
        <GameMap zones={zones} markers={markers} follow={coords} />

        <div className="absolute top-4 left-4 flex flex-col items-start gap-2">
          <div className="flex items-center gap-3 rounded-full border-2 border-border-strong bg-bg-surface py-2 pr-4 pl-2 shadow-md">
            <span className="grid size-10 place-items-center rounded-full border-2 border-border-brand bg-bg-brand-subtle type-heading-l text-text-brand">
              {granny.name[0]}
            </span>
            <div>
              <div className="type-label-m">{granny.name}</div>
              <div className="type-body-s text-text-secondary">{granny.is_romling ? "Rømlingen" : "Granny"}</div>
            </div>
            {granny.caught ? <Badge tone="danger">Fanget</Badge> : <Badge tone="success">Fri</Badge>}
          </div>
          {tgAge !== undefined && !granny.caught && (
            <Link
              to="/granny/telegram"
              className={`flex items-center gap-1 rounded-full border border-border-strong px-3 py-1 type-label-s ${tgOk ? "bg-bg-success-subtle" : "bg-bg-warning"}`}
            >
              <Icon name="send" size={16} />
              {tgOk ? `Telegram live · ${tgAge} s` : "Telegram: ingen posisjon – trykk her"}
            </Link>
          )}
          {gpsError && <div className="rounded-md bg-bg-danger-subtle px-3 py-2 type-body-s">{gpsError}</div>}
        </div>

        {granny.caught ? (
          <div className="absolute inset-x-4 bottom-6"><CaughtCard grannyId={granny.id} /></div>
        ) : (
          <div className="absolute inset-x-4 bottom-5 flex gap-3">
            {/* Kamera og taxi kommer i neste steg */}
            <Button icon="camera" className="flex-1" disabled>Ta bilde</Button>
            <Button icon="taxi" variant="secondary" disabled>Taxi</Button>
          </div>
        )}
        {!granny.caught && <GrannyCatchDialog onResolved={refresh} />}
      </main>
    </Screen>
  );
}
