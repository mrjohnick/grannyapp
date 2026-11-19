// L1 · Kart (letelag), L2 fangst, L3–L6 oppgaver, L7 · Blindet
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { useGame } from "../lib/game";
import { useEventVersion } from "../lib/events";
import { tagText, useFamilies } from "../lib/families";
import { useDevicePosition, useInterval, useOnPing, useWakeLock } from "../lib/hooks";
import { useZones } from "../lib/useZones";
import { inZone } from "../lib/geo";
import { GameMap, zoneMarkers } from "../map/GameMap";
import { Badge, Button, Screen, TeamDot, TopBar } from "../components/ui";
import { Icon, type IconName } from "../components/Icon";
import { PushChip } from "../components/PushChip";
import { formatCountdown, formatGameTime } from "../lib/gameClock";
import type { MapMarker, TeamMap, TeamStatus } from "../lib/types";
import { TeamCatchSheet, TeamCatchStatus } from "../features/catch";
import { QuestSheet } from "../features/quests";
import { AlbumRevealSheet, markAlbumSeen, NabovaktSheet, PostkortSheet, RomlingSheet, ScoreSheet, unseenAlbumPhoto } from "../features/team";

type Panel = "catch" | "nabovakt" | "romling" | "postkort" | "score" | "quests" | null;

const LIVE_TEXT = { sladret: "sladret på", spilleder: "vist av spilleder", evne: "deres evne", utenfor: "utenfor området", bingo: "Bingo" } as const;

export function TeamHome() {
  const { state, gameS, refresh } = useGame();
  const { version } = useEventVersion();
  const team = state.team!;
  const zones = useZones();
  const { coords } = useDevicePosition(state.status !== "ended");
  useWakeLock(state.status === "running");

  const [map, setMap] = useState<TeamMap | null>(null);
  const [status, setStatus] = useState<TeamStatus | null>(null);
  const [pingFlash, setPingFlash] = useState(false);
  const [panel, setPanel] = useState<Panel>(null);
  const [catchKey, setCatchKey] = useState(0);
  const [notice, setNotice] = useState<string | null>(null);
  const { tagOf, avatarOf } = useFamilies();
  const [abilities, setAbilities] = useState(0);
  const [quests, setQuests] = useState(0);
  const loadQuests = useCallback(async () => {
    const { data } = await supabase.rpc("team_quests");
    if (!data) return;
    const q = data as { abilities_left: number; quests: Array<{ status: string | null; closed: boolean }> };
    setAbilities(q.abilities_left);
    setQuests(q.quests.filter((x) => !x.closed && x.status !== "approved" && x.status !== "pending").length);
  }, []);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("team_map");
    if (!error) setMap(data as TeamMap);
  }, []);
  const loadStatus = useCallback(async () => {
    const { data, error } = await supabase.rpc("team_status");
    if (!error) setStatus(data as TeamStatus);
  }, []);
  // Live-markører (sladret, utenfor, Bingo) endrer seg mellom pingene, så vi spør jevnlig.
  useInterval(load, 10_000);
  useInterval(loadStatus, 20_000);
  useEffect(() => { if (version) { load(); loadStatus(); setCatchKey((k) => k + 1); } }, [version, load, loadStatus]);
  useInterval(loadQuests, 20_000);
  useEffect(() => { loadQuests(); }, [version, loadQuests]);
  useOnPing(state.ping_schedule_s, gameS, () => {
    // Litt forsinkelse, så siste Telegram-posisjon før pinget rekker å komme inn.
    setTimeout(() => { load(); refresh(); }, 1500);
    setPingFlash(true);
    setTimeout(() => setPingFlash(false), 6000);
  });

  const blindUntil = map?.blind_until_s ?? team.blind_until_s;
  const blind = blindUntil != null && blindUntil > gameS;
  // Når blindheten er over, viser vi bildet som blindet laget (én gang per bilde).
  const albumPhoto = blind || panel ? null : unseenAlbumPhoto(status, team.id);

  const markers = useMemo<MapMarker[]>(() => {
    if (blind) return [];
    const list = zoneMarkers(zones);
    for (const m of map?.markers ?? []) {
      if (m.kind === "taxi") {
        list.push({ key: `taxi-${m.at_s}-${m.lat}`, kind: "taxi", lat: m.lat, lng: m.lng, label: `Taxi hentet her · ${formatGameTime(m.at_s)}` });
        continue;
      }
      // Hver granny merkes med familien sin (laget) eller «★ Bonus».
      const tag = m.kind === "own_granny" ? "Deres" : tagText(tagOf(m.id));
      const who = tag ? `${m.name} (${tag})` : m.name;
      const label = m.kind === "romling" ? "???"
        : m.kind === "anonym" ? "Noen sladret"
        : m.live_reason ? `${who} · ${LIVE_TEXT[m.live_reason]}` : who;
      list.push({ key: m.id ?? `${m.kind}-${m.at_s}`, kind: m.kind, lat: m.lat, lng: m.lng, label, avatarUrl: m.kind === "romling" ? null : avatarOf(m.id) });
    }
    if (coords) list.push({ key: "meg", kind: "meg", lat: coords.lat, lng: coords.lng, label: "Dere" });
    return list;
  }, [blind, zones, map, coords, tagOf, avatarOf]);

  const free = map?.markers.filter((m) => m.kind !== "romling" && m.kind !== "anonym" && m.kind !== "taxi").length ?? 0;
  const running = state.status === "running";
  const hunting = running && gameS >= state.head_start_s;
  const openCard = status?.postcards.find((p) => gameS < p.closes_at_s && !p.won_by);
  const nearNabovakt = zones.some((z) => z.kind === "nabovakt" && inZone(z, coords));
  const nattevakt = zones.find((z) => z.kind === "nattevakt");
  const atPost = !!nattevakt && inZone(nattevakt, coords);
  const romlingOut = gameS >= state.romling_reveal_s;

  const actions: Array<{ key: Panel; icon: IconName; label: string; badge?: string; hot?: boolean; show: boolean }> = [
    { key: "nabovakt", icon: "eye", label: "Nabovakt", hot: nearNabovakt, show: true },
    { key: "postkort", icon: "camera", label: "Postkort", badge: openCard ? formatCountdown(openCard.closes_at_s - gameS) : undefined, hot: !!openCard, show: true },
    { key: "romling", icon: "moon", label: "Rømlingen", hot: atPost && !status?.has_license, badge: status?.has_license ? "Lisens" : undefined, show: romlingOut },
    { key: "quests", icon: "list", label: "Quests", badge: abilities > 0 ? `${abilities} evne${abilities === 1 ? "" : "r"}` : quests > 0 ? String(quests) : undefined, hot: abilities > 0, show: true },
    { key: "score", icon: "trophy", label: status ? `${status.points}p` : "Poeng", show: true },
  ];

  return (
    <Screen className={blind ? "theme-dark" : ""}>
      <TopBar gameS={gameS} nextPingS={state.next_ping_s} status={state.status} blindUntilS={blindUntil} />
      <main className="relative flex-1">
        {blind ? (
          <div className="flex h-full flex-col items-center justify-center gap-4 px-6 text-center">
            <span className="grid size-24 place-items-center rounded-full bg-bg-surface-raised"><Icon name="eye-off" size={40} /></span>
            <h1 className="type-display-xl">Dere er blinde.</h1>
            <p className="type-body-l text-text-secondary">Ingen kart, ping eller taxivarsler. Bruk øynene. Dere kan fortsatt fange grannies dere ser.</p>
            <div className="w-full rounded-lg border-2 border-border-strong bg-bg-surface p-4">
              <div className="type-label-caps">Kartet er tilbake om</div>
              <div className="type-timer-xl">{formatCountdown(blindUntil! - gameS)}</div>
            </div>
          </div>
        ) : (
          <GameMap zones={zones} markers={markers} />
        )}

        <div className="absolute inset-x-4 top-3 flex flex-col items-start gap-2">
          {!blind && pingFlash && map?.ping_s != null && (
            <div className="flex w-full items-center gap-3 rounded-lg border-2 border-border-strong bg-bg-surface p-3 shadow-hard">
              <span className="grid size-10 place-items-center rounded-full bg-bg-brand-subtle text-icon-brand"><Icon name="ping" size={20} /></span>
              <div>
                <div className="type-label-m">Ping! Kartet er oppdatert.</div>
                <div className="type-body-s text-text-secondary">
                  {free} grannies på kartet.{state.next_ping_s != null ? ` Neste ping ${formatGameTime(state.next_ping_s)}.` : ""}
                </div>
              </div>
            </div>
          )}
          <PushChip />
          {notice && (
            <button type="button" onClick={() => setNotice(null)} className="rounded-md bg-bg-success-subtle px-3 py-2 text-left type-label-s">
              {notice}
            </button>
          )}
        </div>

        <div className="absolute inset-x-4 bottom-5 flex flex-col items-start gap-3">
          <div className="flex items-center gap-2 rounded-full border-2 border-border-strong bg-bg-surface py-2 pr-3 pl-2">
            <TeamDot color={team.color} />
            <span className="type-label-m">{team.name}</span>
            {team.assigned_granny_name && <Badge tone="warning">Deres: {team.assigned_granny_name}</Badge>}
          </div>
          <TeamCatchStatus refreshKey={catchKey} />
          {state.status === "ended" ? (
            <Link to="/oppsummering" className="block w-full"><Button icon="trophy" block>Se oppsummeringen</Button></Link>
          ) : (
            <>
              <div className="grid w-full gap-2" style={{ gridTemplateColumns: `repeat(${actions.filter((a) => a.show).length}, minmax(0, 1fr))` }}>
                {actions.filter((a) => a.show).map((a) => (
                  <button
                    key={a.key}
                    type="button"
                    disabled={!status || (a.key !== "score" && a.key !== "quests" && !hunting)}
                    onClick={() => setPanel(a.key)}
                    className={`relative flex flex-col items-center gap-1 rounded-lg border-2 border-border-strong py-2 shadow-hard active:translate-y-[2px] active:shadow-none disabled:opacity-50 ${
                      a.hot ? "bg-bg-accent" : "bg-bg-surface"
                    }`}
                  >
                    <Icon name={a.icon} size={22} />
                    <span className="type-label-s">{a.label}</span>
                    {a.badge && <span className="absolute -top-2 -right-1 rounded-full bg-bg-inverse px-2 type-label-caps text-text-inverse">{a.badge}</span>}
                  </button>
                ))}
              </div>
              <Button icon="target" block disabled={!running} onClick={() => setPanel("catch")}>Fang granny</Button>
            </>
          )}
        </div>

        {panel === "catch" && (
          <TeamCatchSheet
            state={state}
            gameS={gameS}
            onClose={() => setPanel(null)}
            onRegistered={() => { setPanel(null); setCatchKey((k) => k + 1); load(); }}
          />
        )}
        {panel === "nabovakt" && status && (
          <NabovaktSheet status={status} zones={zones} coords={coords} gameS={gameS} onClose={() => setPanel(null)} onDone={loadStatus} />
        )}
        {panel === "romling" && status && (
          <RomlingSheet status={status} zones={zones} coords={coords} gameS={gameS} onClose={() => setPanel(null)}
            onDone={() => { loadStatus(); refresh(); load(); }} />
        )}
        {panel === "postkort" && status && (
          <PostkortSheet status={status} gameS={gameS} gameId={state.game_id} coords={coords} onClose={() => setPanel(null)}
            onDone={(msg) => { setPanel(null); setNotice(msg); loadStatus(); }} />
        )}
        {panel === "quests" && (
          <QuestSheet gameId={state.game_id} blind={blind} onClose={() => setPanel(null)} onChanged={() => { loadQuests(); load(); }} />
        )}
        {panel === "score" && status && <ScoreSheet status={status} teamId={team.id} onClose={() => setPanel(null)} />}
        {albumPhoto && status && (
          <AlbumRevealSheet photo={albumPhoto} onClose={() => { markAlbumSeen(status, team.id); setStatus({ ...status }); }} />
        )}
      </main>
    </Screen>
  );
}
