// G1 · Kart (granny), med G2–G4 (taxi, sladring, bilder) og G5/G6 (fangst)
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { useGame } from "../lib/game";
import { useEventVersion } from "../lib/events";
import { useFamilies } from "../lib/families";
import { useDevicePosition, useInterval, useWakeLock } from "../lib/hooks";
import { useZones } from "../lib/useZones";
import { GameMap, zoneMarkers } from "../map/GameMap";
import { Badge, Button, Screen, TopBar } from "../components/ui";
import { Icon } from "../components/Icon";
import { PushChip } from "../components/PushChip";
import { Avatar } from "../components/Avatar";
import type { GrannyMap, GrannyStatus, MapMarker } from "../lib/types";
import { CaughtCard } from "../features/catch";
import { QuestSheet } from "../features/quests";
import { GrannyPoints, SnitchSheet, TaxiSheet } from "../features/granny";
import { CameraCapture, uploadPhoto } from "../features/camera";

type Panel = "taxi" | "snitch" | "quests" | null;

export function GrannyHome() {
  const { state, gameS, refresh } = useGame();
  const { version } = useEventVersion();
  const granny = state.granny!;
  const [avatarKey, setAvatarKey] = useState(0);
  const { tagOf, avatarOf } = useFamilies(avatarKey);
  const tag = tagOf(granny.id);
  const [selfie, setSelfie] = useState(false);
  const zones = useZones();
  const [status, setStatus] = useState<GrannyStatus | null>(null);
  // En fanget granny trenger GPS bare når hun har bestilt taxi (sjåføren skal finne henne).
  const { coords, error: gpsError } = useDevicePosition(state.status !== "ended" && (!granny.caught || !!status?.taxi_request));
  useWakeLock(state.status === "running");

  const [tgAge, setTgAge] = useState<number | null | undefined>(undefined);
  const loadTelegram = useCallback(async () => {
    const { data } = await supabase.rpc("my_telegram");
    if (data) setTgAge((data as { last_position_age_s: number | null }).last_position_age_s);
  }, []);
  useInterval(loadTelegram, 15_000);

  const [map, setMap] = useState<GrannyMap | null>(null);
  const load = useCallback(async () => {
    const [st, mp] = await Promise.all([supabase.rpc("granny_status"), supabase.rpc("granny_map")]);
    if (st.data) setStatus(st.data as GrannyStatus);
    if (mp.data) setMap(mp.data as GrannyMap);
  }, []);
  useInterval(load, 15_000);
  useEffect(() => { if (version) load(); }, [version, load]);

  const [panel, setPanel] = useState<Panel>(null);
  const [notice, setNotice] = useState<string | null>(null);


  const markers = useMemo<MapMarker[]>(() => {
    const list = zoneMarkers(zones);
    for (const m of map?.markers ?? []) {
      if (m.kind === "taxi") list.push({ key: `taxi-${m.id}`, kind: "taxi", lat: m.lat, lng: m.lng, label: m.busy ? `${m.name} · opptatt` : m.name });
      else list.push({ key: `anonym-${m.at_s}`, kind: "anonym", lat: m.lat, lng: m.lng, label: "Noen sladret" });
    }
    if (coords) list.push({ key: "meg", kind: "meg", lat: coords.lat, lng: coords.lng, label: "Deg" });
    return list;
  }, [zones, map, coords]);

  const tgOk = tgAge != null && tgAge <= 60;
  const running = state.status === "running";
  const active = running && !granny.caught;

  return (
    <Screen>
      <TopBar gameS={gameS} nextPingS={state.next_ping_s} status={state.status} caught={granny.caught} />
      <main className="relative flex-1">
        <GameMap zones={zones} markers={markers} follow={coords} />

        <div className="absolute top-4 left-4 right-4 flex flex-col items-start gap-2">
          <div className="flex items-center gap-3 rounded-full border-2 border-border-strong bg-bg-surface py-2 pr-4 pl-2 shadow-md">
            <Avatar name={granny.name} url={avatarOf(granny.id)} />
            <div>
              <div className="type-label-m">{granny.name}</div>
              <div className="type-body-s text-text-secondary">
                {granny.is_romling ? "Rømlingen"
                  : tag?.kind === "family" ? `Granny · familien din er ${tag.team.name}`
                  : tag?.kind === "bonus" ? "★ Bonus-granny · ingen egen familie"
                  : "Granny"}
              </div>
            </div>
            {granny.caught ? <Badge tone="danger">Fanget</Badge> : <Badge tone="success">Fri</Badge>}
          </div>
          <GrannyPoints status={status} isRomling={granny.is_romling} />
          {tgAge !== undefined && !granny.caught && state.status !== "ended" && (tgOk ? (
            <Link to="/granny/telegram"
              className="flex items-center gap-1 rounded-full border border-border-strong bg-bg-success-subtle px-3 py-1 type-label-s">
              <Icon name="send" size={16} /> Telegram live · {tgAge} s
            </Link>
          ) : (
            // Uten live-posisjon fra Telegram er hun ikke med på pingene. Si tydelig fra.
            <Link to="/granny/telegram"
              className="flex w-full max-w-sm items-center gap-3 rounded-lg border-2 border-border-strong bg-bg-warning p-3 shadow-hard">
              <Icon name="send" size={24} />
              <span className="flex-1">
                <span className="block type-label-m">
                  {tgAge === null ? "Del posisjonen din i Telegram" : "Telegram sender ikke posisjonen din"}
                </span>
                <span className="block type-body-s">
                  {tgAge === null ? "Uten den er du ikke med på pingene. Trykk her." : `Sist for ${Math.round(tgAge / 60)} min siden. Del live-posisjon på nytt.`}
                </span>
              </span>
            </Link>
          ))}
          <PushChip />
          {!granny.avatar_path && state.status !== "ended" && (
            <button type="button" onClick={() => setSelfie(true)}
              className="flex items-center gap-1 rounded-full border border-border-strong bg-bg-warning px-3 py-1 type-label-s">
              <Icon name="camera" size={16} /> Ta profilbilde, så lagene ser hvem du er
            </button>
          )}
          {granny.is_romling && status && !status.license_given && !granny.caught && (
            <div className="rounded-md bg-bg-info-subtle px-3 py-2 type-body-s">Du kan være innendørs til et lag har knekt koden.</div>
          )}
          {gpsError && <div className="rounded-md bg-bg-danger-subtle px-3 py-2 type-body-s">{gpsError}</div>}
          {notice && (
            <button type="button" onClick={() => setNotice(null)} className="rounded-md bg-bg-success-subtle px-3 py-2 text-left type-label-s">
              {notice}
            </button>
          )}
        </div>

        <div className="absolute inset-x-4 bottom-5 flex flex-col gap-3">
          {state.status === "ended" && (
            <div className="w-full rounded-lg border-2 border-border-strong bg-bg-surface p-4 shadow-hard">
              <div className="type-heading-m">Spillet er over</div>
              <p className="type-body-s text-text-secondary">Takk for jakten! Spilleder kårer vinnerne.</p>
            </div>
          )}
          {granny.caught && state.status !== "ended" && <CaughtCard grannyId={granny.id} />}
          {granny.caught && running && (
            <Button icon="taxi" variant="secondary" block disabled={!status} onClick={() => setPanel("taxi")}>
              {status?.taxi_request ? "Taxien din" : "Bestill taxi"}
            </Button>
          )}
          {!granny.caught && state.status !== "ended" && (
            <div className="flex gap-3">
              {!granny.is_romling && (
                <Button icon="list" className="flex-1" disabled={!active || !status} onClick={() => setPanel("quests")}>Oppdrag</Button>
              )}
              <Button icon="taxi" variant="secondary" className={granny.is_romling ? "flex-1" : ""} disabled={!active || !status} onClick={() => setPanel("taxi")}>
                Taxi
              </Button>
              {!granny.is_romling && (
                <Button
                  icon="megaphone"
                  variant="secondary"
                  disabled={!active || !status || status.snitch_used}
                  onClick={() => setPanel("snitch")}
                  aria-label="Sladre"
                />
              )}
            </div>
          )}
        </div>

        {panel === "taxi" && status && (
          <TaxiSheet status={status} coords={coords} gameS={gameS} caught={granny.caught}
            taxisOnline={(map?.markers ?? []).filter((m) => m.kind === "taxi").length} onClose={() => setPanel(null)} onDone={load} />
        )}
        {selfie && (
          <CameraCapture
            title="Profilbilde"
            hint="Ansiktet ditt vises på kartet ved siden av navnet."
            selfie
            onClose={() => setSelfie(false)}
            onSend={async (blob) => {
              const path = await uploadPhoto(state.game_id, blob, "avatar-");
              const { error } = await supabase.rpc("granny_set_avatar", { p_path: path });
              if (error) throw new Error("Profilbildet ble ikke lagret. Prøv igjen.");
              setSelfie(false);
              setAvatarKey((k) => k + 1);
              refresh();
            }}
          />
        )}
        {panel === "snitch" && status && (
          <SnitchSheet status={status} coords={coords} avatarOf={avatarOf}
            onClose={() => setPanel(null)}
            onDone={(s) => { setStatus(s); setPanel(null); setNotice("Du har sladret. Lagene ser hvor hun er nå."); load(); }} />
        )}
        {panel === "quests" && (
          <QuestSheet role="granny" onClose={() => setPanel(null)} onChanged={load} />
        )}
      </main>
    </Screen>
  );
}
