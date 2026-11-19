// Varsler i appen. Henter nye rader fra my_events() hvert 4. sekund og viser
// dem som kort øverst. Web Push (game-worker) sender de samme varslene når
// appen er lukket.
import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { supabase } from "./supabase";
import { useInterval } from "./hooks";
import type { GameEvent } from "./types";
import { Icon, type IconName } from "../components/Icon";

type Ctx = { version: number; last: GameEvent | null };
const EventsContext = createContext<Ctx>({ version: 0, last: null });

/** Øker hver gang et nytt varsel kommer. Bruk som avhengighet for å hente data på nytt. */
export function useEventVersion() {
  return useContext(EventsContext);
}

const ICONS: Record<string, IconName> = {
  ping: "ping", taxi: "taxi", snitch: "megaphone", snitch_target: "megaphone", snitch_bonus: "megaphone",
  blind: "eye-off", blind_over: "eye", bingo: "bingo", bingo_ok: "bingo",
  nabovakt_seen: "eye", nabovakt_result: "eye", postkort_open: "camera", postkort_won: "camera", postkort_closed: "camera",
  romling_reveal: "moon", license: "lock", catch_registered: "target", catch_confirmed: "target", catch_overdue: "alert",
  photo_pending: "camera", photo_approved: "check", photo_rejected: "x", message: "bell", end: "trophy", start: "play",
  pause: "pause", resume: "play", reveal: "eye", reveal_target: "eye",
  taxi_request: "taxi", taxi_accepted: "taxi", taxi_cancelled: "taxi", taxi_released: "taxi",
  quest_new: "list", quest_pending: "list", quest_approved: "check", quest_rejected: "x",
  ability_used: "eye", ability_target: "eye",
};

const URGENT = new Set(["catch_registered", "snitch_target", "reveal_target", "ability_target", "taxi_request", "taxi_accepted", "quest_new", "nabovakt_seen", "blind", "license", "catch_overdue", "romling_reveal"]);
const SHOW_FOR_MS = 9000;
const storageKey = (gameId: string) => `granny.events.${gameId}`;

export function EventsProvider({ gameId, onEvent, children }: { gameId: string; onEvent?: (e: GameEvent) => void; children: ReactNode }) {
  const [toasts, setToasts] = useState<Array<GameEvent & { shownAt: number }>>([]);
  const [ctx, setCtx] = useState<Ctx>({ version: 0, last: null });
  const lastId = useRef<number | null>(null);
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  if (lastId.current === null) {
    const stored = Number(localStorage.getItem(storageKey(gameId)) ?? "0");
    lastId.current = Number.isFinite(stored) ? stored : 0;
  }

  const poll = useCallback(async () => {
    const { data, error } = await supabase.rpc("my_events", { p_after: lastId.current ?? 0 });
    if (error || !data) return;
    // To henteforsøk kan overlappe (f.eks. ved oppstart). Ta bare med det som er nytt.
    const events = (data as GameEvent[]).filter((e) => e.id > (lastId.current ?? 0));
    if (events.length === 0) return;
    lastId.current = events[events.length - 1].id;
    try { localStorage.setItem(storageKey(gameId), String(lastId.current)); } catch { /* privat modus */ }
    // Ikke vis gamle varsler som et skred når appen åpnes igjen.
    const fresh = events.filter((e) => Date.now() - new Date(e.created_at).getTime() < 3 * 60_000);
    if (fresh.length) {
      setToasts((t) => [...t, ...fresh.map((e) => ({ ...e, shownAt: Date.now() }))].slice(-4));
      if (fresh.some((e) => URGENT.has(e.kind))) navigator.vibrate?.([200, 100, 200]);
    }
    setCtx((c) => ({ version: c.version + 1, last: events[events.length - 1] }));
    for (const e of events) onEventRef.current?.(e);
  }, [gameId]);

  useInterval(poll, 4000);
  useEffect(() => {
    const onVisible = () => document.visibilityState === "visible" && poll();
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [poll]);
  useInterval(() => setToasts((t) => t.filter((x) => Date.now() - x.shownAt < SHOW_FOR_MS)), 1000, toasts.length > 0);

  return (
    <EventsContext.Provider value={ctx}>
      {children}
      {toasts.length > 0 && (
        <div className="pointer-events-none fixed inset-x-0 top-0 z-50 flex flex-col items-center gap-2 px-3 pt-[max(12px,env(safe-area-inset-top))]">
          {toasts.map((t) => (
            <button
              key={t.id}
              type="button"
              onClick={() => setToasts((all) => all.filter((x) => x.id !== t.id))}
              className={`pointer-events-auto flex w-full max-w-md items-center gap-3 rounded-lg border-2 border-border-strong p-3 text-left shadow-hard ${
                URGENT.has(t.kind) ? "bg-bg-warning" : "bg-bg-surface"
              }`}
            >
              <span className="grid size-10 shrink-0 place-items-center rounded-full bg-bg-brand-subtle text-icon-brand">
                <Icon name={ICONS[t.kind] ?? "bell"} size={20} />
              </span>
              <span className="min-w-0">
                <span className="block type-label-m">{t.title}</span>
                {t.body && <span className="block type-body-s text-text-secondary">{t.body}</span>}
              </span>
            </button>
          ))}
        </div>
      )}
    </EventsContext.Provider>
  );
}
