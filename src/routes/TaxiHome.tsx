// Taxisjåfør: kø, neste tur, hent og lever. Grannyens posisjon vises bare til hun er hentet.
import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase } from "../lib/supabase";
import { useGame } from "../lib/game";
import { useEventVersion } from "../lib/events";
import { useDevicePosition, useInterval, useWakeLock } from "../lib/hooks";
import { useZones } from "../lib/useZones";
import { friendly } from "../lib/errors";
import { distanceM, distanceText } from "../lib/geo";
import { formatCountdown } from "../lib/gameClock";
import { GameMap, zoneMarkers } from "../map/GameMap";
import { Badge, Button, Screen, TopBar } from "../components/ui";
import { PushChip } from "../components/PushChip";
import { TelegramChip } from "../components/TelegramAlerts";
import { Avatar } from "../components/Avatar";
import { photoUrl } from "../features/camera";
import type { MapMarker, TaxiQueue } from "../lib/types";

function ageText(s: number) {
  return s < 60 ? `${s} sek` : `${Math.round(s / 60)} min`;
}

export function TaxiHome() {
  const { state, gameS } = useGame();
  const { version } = useEventVersion();
  const zones = useZones();
  const running = state.status === "running";
  // Sjåføren sender posisjon oftere, så grannyene ser taxien bevege seg.
  const { coords, error: gpsError } = useDevicePosition(state.status !== "ended", 10_000);
  useWakeLock(running);

  const [queue, setQueue] = useState<TaxiQueue | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [avatar, setAvatar] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("taxi_queue");
    if (!error) setQueue(data as TaxiQueue);
  }, []);
  useInterval(load, 4000);
  useEffect(() => { load(); }, [version, load]);

  const active = queue?.active ?? null;
  useEffect(() => {
    let alive = true;
    if (active?.granny_avatar) photoUrl(active.granny_avatar).then((u) => alive && setAvatar(u));
    else setAvatar(null);
    return () => { alive = false; };
  }, [active?.granny_avatar]);

  async function call(fn: string, args: Record<string, unknown> = {}) {
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) setError(friendly(error));
    load();
  }
  const pos = { p_lat: coords?.lat ?? null, p_lng: coords?.lng ?? null, p_accuracy: coords?.accuracy ?? null };

  const markers = useMemo<MapMarker[]>(() => {
    const list = zoneMarkers(zones.filter((z) => z.kind === "area"));
    if (active?.lat != null && active.lng != null) {
      list.push({ key: "granny", kind: "live", lat: active.lat, lng: active.lng, label: active.granny_name, avatarUrl: avatar });
    }
    if (coords) list.push({ key: "meg", kind: "meg", lat: coords.lat, lng: coords.lng, label: "Du" });
    return list;
  }, [zones, active, coords, avatar]);

  const dist = active?.lat != null && active.lng != null && coords ? distanceM(coords, { lat: active.lat, lng: active.lng }) : null;
  const waiting = queue?.waiting ?? [];

  return (
    <Screen>
      <TopBar gameS={gameS} nextPingS={null} status={state.status} />
      <main className="relative flex-1">
        <GameMap zones={zones.filter((z) => z.kind === "area")} markers={markers} follow={coords} />

        <div className="absolute top-4 left-4 right-4 flex flex-col items-start gap-2">
          <div className="flex items-center gap-2 rounded-full border-2 border-border-strong bg-bg-surface py-2 pr-4 pl-3 shadow-md">
            <Badge tone="warning">Taxi</Badge>
            <span className="type-label-m">{state.taxi?.name}</span>
          </div>
          <PushChip />
          <TelegramChip />
          {gpsError && <div className="rounded-md bg-bg-danger-subtle px-3 py-2 type-body-s">{gpsError}</div>}
        </div>

        <div className="absolute inset-x-0 bottom-0 flex flex-col gap-3 rounded-t-xl border-t-2 border-border-strong bg-bg-surface p-4 pb-[max(16px,env(safe-area-inset-bottom))]">
          {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}

          {active ? (
            <>
              <div className="flex items-center gap-3">
                <Avatar name={active.granny_name} url={avatar} size={48} />
                <div className="flex-1">
                  <div className="type-heading-m">{active.granny_name}</div>
                  <div className="type-body-s text-text-secondary">
                    {active.status === "accepted"
                      ? dist != null ? `${distanceText(dist)} unna · hent henne`
                        : active.lat != null ? "Hent henne · se kartet" : "Venter på posisjonen hennes"
                      : "I bilen · kjør dit hun vil"}
                  </div>
                  {active.status === "accepted" && active.position_age_s != null && (
                    <div className={`type-body-s ${active.position_age_s > 120 ? "text-text-danger" : "text-text-tertiary"}`}>
                      Posisjonen er {ageText(active.position_age_s)} gammel{active.position_age_s > 120 ? " – hun kan ha flyttet seg" : ""}
                    </div>
                  )}
                </div>
                <Badge tone={active.status === "accepted" ? "warning" : "success"}>{active.status === "accepted" ? "På vei" : "I bilen"}</Badge>
              </div>
              {active.status === "accepted" && (
                <p className="rounded-md bg-bg-warning-subtle px-3 py-2 type-body-s">
                  Hold appen åpen til hun er hentet. Sender den ikke posisjon på {Math.round((queue?.timeout_s ?? 300) / 60)} min, går turen til en annen taxi.
                </p>
              )}
              {active.status === "accepted" ? (
                <div className="flex gap-2">
                  <Button className="flex-1" icon="check" disabled={busy || !running} onClick={() => call("taxi_pickup", pos)}>Hentet</Button>
                  <Button variant="secondary" disabled={busy} onClick={() => confirm("Gi fra deg turen? Grannyen havner først i køen igjen.") && call("taxi_release")}>
                    Gi fra meg
                  </Button>
                </div>
              ) : (
                <Button block icon="check" disabled={busy} onClick={() => call("taxi_dropoff")}>Levert</Button>
              )}
            </>
          ) : (
            <>
              <div className="flex items-baseline justify-between">
                <h2 className="type-heading-m">Køen</h2>
                <span className="type-body-s text-text-secondary">{queue ? `${queue.busy} på tur nå` : ""}</span>
              </div>
              {waiting.length === 0 ? (
                <p className="type-body-m text-text-secondary">Ingen venter. Kjør rundt, så grannyene ser deg på kartet.</p>
              ) : (
                <ol className="flex flex-col gap-1">
                  {waiting.map((w, i) => (
                    <li key={w.id} className={`flex items-center gap-2 rounded-md px-3 py-2 ${i === 0 ? "bg-bg-warning-subtle" : ""}`}>
                      <span className="w-5 type-label-m text-text-tertiary">{i + 1}</span>
                      <span className="flex-1 type-label-m">{w.granny_name}</span>
                      <span className="type-timer-s text-text-tertiary">venter {formatCountdown(Math.max(0, gameS - w.requested_s))}</span>
                    </li>
                  ))}
                </ol>
              )}
              <Button block icon="taxi" disabled={busy || !running || waiting.length === 0} onClick={() => call("taxi_accept_next")}>
                {waiting.length > 0 ? `Ta turen til ${waiting[0].granny_name}` : "Ta neste tur"}
              </Button>
              {!running && <p className="type-body-s text-text-tertiary">Du kan ta turer når spillet er i gang.</p>}
            </>
          )}
        </div>
      </main>
    </Screen>
  );
}
