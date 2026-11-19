// Varsler i appen. Henter hele historikken fra my_event_history() ved oppstart og
// når appen kommer tilbake i forgrunnen, og nye rader fra my_events() hvert
// 4. sekund. Nye varsler vises som kort øverst. Alle varsler samles på
// varslingssiden (#varsler), som bjella (<NotificationBell>) åpner.
// Web Push (game-worker) sender de samme varslene når appen er lukket.
import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { supabase } from "./supabase";
import { useInterval } from "./hooks";
import { formatGameTime } from "./gameClock";
import { loginLink, useMyCode } from "./joinCode";
import type { GameEvent } from "./types";
import { Icon, type IconName } from "../components/Icon";
import { TelegramBanner } from "../components/TelegramAlerts";

type Ctx = {
  version: number;
  last: GameEvent | null;
  history: GameEvent[];
  unread: number;
  openPage: () => void;
};
const EventsContext = createContext<Ctx>({ version: 0, last: null, history: [], unread: 0, openPage: () => {} });

/** Øker hver gang et nytt varsel kommer. Bruk som avhengighet for å hente data på nytt. */
export function useEventVersion() {
  return useContext(EventsContext);
}

const ICONS: Record<string, IconName> = {
  ping: "ping", taxi: "taxi", snitch: "megaphone", snitch_target: "megaphone", snitch_bonus: "megaphone",
  blind: "eye-off", blind_over: "eye", album_photo: "camera", bingo: "bingo", bingo_ok: "bingo",
  nabovakt_seen: "eye", nabovakt_result: "eye", postkort_open: "camera", postkort_won: "camera", postkort_closed: "camera",
  romling_reveal: "moon", license: "lock", catch_registered: "target", catch_pending: "target", catch_confirmed: "target", catch_overdue: "alert",
  photo_pending: "camera", photo_approved: "check", photo_rejected: "x", message: "bell", end: "trophy", start: "play",
  pause: "pause", resume: "play", reveal: "eye", reveal_target: "eye",
  taxi_request: "taxi", taxi_accepted: "taxi", taxi_cancelled: "taxi", taxi_released: "taxi",
  taxi_warning: "alert", taxi_timeout: "taxi",
  taxi_ride_started: "taxi", taxi_ride_warning: "alert", taxi_ride_over: "taxi",
  quest_new: "list", quest_pending: "list", quest_approved: "check", quest_rejected: "x",
  ability_used: "eye", ability_target: "eye", pinged: "ping",
  out_of_area: "alert", out_live: "alert", out_back: "check",
};

const URGENT = new Set(["out_of_area", "out_live", "pinged", "taxi_warning", "taxi_timeout", "taxi_released", "taxi_ride_warning", "taxi_ride_over", "catch_registered", "snitch_target", "reveal_target", "ability_target", "taxi_request", "taxi_accepted", "quest_new", "nabovakt_seen", "blind", "license", "catch_overdue", "romling_reveal"]);
const SHOW_FOR_MS = 9000;
const MAX_HISTORY = 300;
const PAGE_HASH = "#varsler";
// Siste varsel som er vist som kort, og siste varsel som er sett på varslingssiden.
const toastKey = (key: string) => `granny.events.${key}`;
const seenKey = (key: string) => `granny.events.seen.${key}`;

function readId(key: string) {
  try {
    const n = Number(localStorage.getItem(key) ?? "0");
    return Number.isFinite(n) ? n : 0;
  } catch { return 0; }
}
function writeId(key: string, id: number) {
  try { localStorage.setItem(key, String(id)); } catch { /* privat modus */ }
}

function mergeById(a: GameEvent[], b: GameEvent[]) {
  const byId = new Map<number, GameEvent>();
  for (const e of a) byId.set(e.id, e);
  for (const e of b) byId.set(e.id, e);
  return [...byId.values()].sort((x, y) => x.id - y.id).slice(-MAX_HISTORY);
}

/** `onEvent` kalles én gang per hentet bunke med nye varsler, med det siste av dem. */
/** `storageKey` skiller lagringen i localStorage (spill + rolle). */
export function EventsProvider({ storageKey, onEvent, children }: { storageKey: string; onEvent?: (e: GameEvent) => void; children: ReactNode }) {
  const [toasts, setToasts] = useState<Array<GameEvent & { shownAt: number }>>([]);
  const [history, setHistory] = useState<GameEvent[]>([]);
  const [version, setVersion] = useState(0);
  const [last, setLast] = useState<GameEvent | null>(null);
  const [seenId, setSeenId] = useState(() => readId(seenKey(storageKey)));
  // Varsler nyere enn dette merkes «Ny» på varslingssiden. Settes når siden åpnes.
  const [newAfter, setNewAfter] = useState(0);

  const loadedId = useRef(0);
  const toastId = useRef<number | null>(null);
  const needFull = useRef(true);
  const inFlight = useRef(false);
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;
  if (toastId.current === null) toastId.current = readId(toastKey(storageKey));

  const location = useLocation();
  const navigate = useNavigate();
  const pageOpen = location.hash === PAGE_HASH;

  const poll = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    try {
      const full = needFull.current;
      const { data, error } = full
        ? await supabase.rpc("my_event_history")
        : await supabase.rpc("my_events", { p_after: loadedId.current });
      if (error || !data) return;
      needFull.current = false;
      const all = data as GameEvent[];
      const fresh = all.filter((e) => e.id > loadedId.current);
      // Full henting fyller også hull etter at appen har ligget i bakgrunnen.
      if (full) setHistory((h) => mergeById(h, all));
      else if (fresh.length) setHistory((h) => mergeById(h, fresh));
      if (fresh.length === 0) return;

      const newest = fresh[fresh.length - 1];
      loadedId.current = newest.id;
      // Ikke vis gamle varsler som et skred når appen åpnes igjen.
      const toShow = fresh.filter((e) => e.id > (toastId.current ?? 0) && Date.now() - new Date(e.created_at).getTime() < 3 * 60_000);
      toastId.current = Math.max(toastId.current ?? 0, newest.id);
      writeId(toastKey(storageKey), toastId.current);
      if (toShow.length) {
        setToasts((t) => [...t, ...toShow.map((e) => ({ ...e, shownAt: Date.now() }))].slice(-4));
        if (toShow.some((e) => URGENT.has(e.kind))) navigator.vibrate?.([200, 100, 200]);
      }
      setVersion((v) => v + 1);
      setLast(newest);
      onEventRef.current?.(newest);
    } finally {
      inFlight.current = false;
    }
  }, [storageKey]);

  useInterval(poll, 4000);
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState !== "visible") return;
      needFull.current = true;
      poll();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [poll]);
  useInterval(() => setToasts((t) => t.filter((x) => Date.now() - x.shownAt < SHOW_FOR_MS)), 1000, toasts.length > 0);

  // Når varslingssiden er åpen, er alt på den sett.
  const newestId = history.length ? history[history.length - 1].id : 0;
  useEffect(() => {
    if (!pageOpen || newestId <= seenId) return;
    setSeenId(newestId);
    writeId(seenKey(storageKey), newestId);
  }, [pageOpen, newestId, seenId, storageKey]);

  const unread = history.reduce((n, e) => (e.id > seenId ? n + 1 : n), 0);

  const openPage = useCallback(() => {
    setNewAfter(seenId);
    setToasts([]);
    navigate({ pathname: location.pathname, search: location.search, hash: PAGE_HASH }, { state: { fromBell: true } });
  }, [navigate, location.pathname, location.search, seenId]);

  // Logg ut: fjern telefonen fra spillet og start helt på nytt på innloggingssiden.
  const logout = useCallback(async () => {
    if (!confirm("Logge ut av spillet? Du trenger koden eller lenken fra spilleder for å komme inn igjen.")) return;
    await supabase.rpc("leave_game");
    await supabase.auth.signOut();
    try {
      Object.keys(localStorage).filter((k) => k.startsWith("granny.")).forEach((k) => localStorage.removeItem(k));
    } catch { /* privat modus */ }
    window.location.replace("/");
  }, []);

  const closePage = useCallback(() => {
    if ((location.state as { fromBell?: boolean } | null)?.fromBell) navigate(-1);
    else navigate({ pathname: location.pathname, search: location.search }, { replace: true });
  }, [navigate, location.pathname, location.search, location.state]);

  return (
    <EventsContext.Provider value={{ version, last, history, unread, openPage }}>
      {children}
      {pageOpen && <NotificationPage history={history} newAfter={newAfter} onClose={closePage} onLogout={logout} />}
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

/** Bjelle med antall uleste varsler. Åpner varslingssiden. */
export function NotificationBell({ className = "" }: { className?: string }) {
  const { unread, openPage } = useContext(EventsContext);
  const label = unread > 0 ? `Varsler, ${unread} uleste` : "Varsler";
  return (
    <button
      type="button"
      onClick={openPage}
      aria-label={label}
      className={`relative grid size-11 shrink-0 place-items-center rounded-full border-2 border-border-strong bg-bg-surface text-text-primary shadow-sm ${className}`}
    >
      <Icon name="bell" size={22} />
      {unread > 0 && (
        <span className="absolute -top-1.5 -right-1.5 grid h-5 min-w-5 place-items-center rounded-full border-2 border-border-strong bg-bg-danger px-1 type-label-s leading-none text-text-on-danger">
          {unread > 99 ? "99+" : unread}
        </span>
      )}
    </button>
  );
}

const clock = new Intl.DateTimeFormat("nb-NO", { hour: "2-digit", minute: "2-digit" });

function NotificationPage({ history, newAfter, onClose, onLogout }: {
  history: GameEvent[]; newAfter: number; onClose: () => void; onLogout: () => void;
}) {
  const list = [...history].reverse();
  const code = useMyCode();
  const [copied, setCopied] = useState(false);
  async function copyLink() {
    if (!code) return;
    try {
      await navigator.clipboard.writeText(loginLink(code));
      setCopied(true);
      setTimeout(() => setCopied(false), 2500);
    } catch { /* Uten utklippstavle: lenken står i feltet og kan markeres. */ }
  }
  return (
    <div role="dialog" aria-modal="true" aria-label="Varsler" className="fixed inset-0 z-40 flex flex-col bg-bg-app">
      <header className="flex items-center gap-3 border-b-2 border-border-strong bg-bg-surface px-4 py-3 pt-[max(12px,env(safe-area-inset-top))]">
        <button type="button" onClick={onClose} className="flex items-center gap-1 type-label-m text-text-brand">
          <Icon name="chevron-left" size={20} /> Tilbake
        </button>
        <h1 className="flex-1 text-center type-heading-m">Varsler</h1>
        <span className="w-[76px]" aria-hidden />
      </header>
      <main className="flex-1 overflow-y-auto px-4 py-3 pb-[max(16px,env(safe-area-inset-bottom))]">
        <TelegramBanner />
        {list.length === 0 ? (
          <p className="mt-10 text-center type-body-m text-text-secondary">Ingen varsler ennå. Meldinger og hendelser i spillet samles her.</p>
        ) : (
          <ol className="mx-auto flex max-w-xl flex-col gap-2">
            {list.map((e) => {
              const isNew = e.id > newAfter;
              return (
                <li
                  key={e.id}
                  className={`flex gap-3 rounded-lg border-2 p-3 ${isNew ? "border-border-strong bg-bg-surface shadow-sm" : "border-border-default bg-bg-surface/60"}`}
                >
                  <span className={`grid size-10 shrink-0 place-items-center rounded-full ${URGENT.has(e.kind) ? "bg-bg-warning" : "bg-bg-brand-subtle"} text-icon-brand`}>
                    <Icon name={ICONS[e.kind] ?? "bell"} size={20} />
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-start gap-2">
                      <span className="flex-1 type-label-m">{e.title}</span>
                      {isNew && <span className="rounded-full bg-bg-danger px-2 py-0.5 type-label-s text-text-on-danger">Ny</span>}
                    </div>
                    {e.body && <p className="type-body-s text-text-secondary">{e.body}</p>}
                    <p className="mt-1 type-body-s text-text-tertiary">
                      {formatGameTime(e.at_s)} i spillet · kl. {clock.format(new Date(e.created_at))}
                    </p>
                  </div>
                </li>
              );
            })}
          </ol>
        )}
        {code && (
          <div className="mx-auto mt-8 flex max-w-xl flex-col gap-2 rounded-lg border border-border-default bg-bg-surface p-3">
            <p className="type-label-m">Din innloggingslenke</p>
            <p className="type-body-s text-text-secondary">
              Åpnet appen inne i Telegram? Kopier lenken og lim den inn i Safari eller Chrome. Der får du varsler og kan legge appen på Hjem-skjermen.
            </p>
            <input readOnly value={loginLink(code)} onFocus={(e) => e.currentTarget.select()} aria-label="Innloggingslenke"
              className="h-10 w-full rounded-sm border border-border-strong bg-bg-app px-2 type-body-s" />
            <div className="flex items-center gap-3">
              <button type="button" onClick={copyLink} className="rounded-full border-2 border-border-strong bg-bg-surface px-4 py-2 type-label-m">
                {copied ? "Kopiert!" : "Kopier lenke"}
              </button>
              <span className="type-body-s text-text-tertiary">Kode: <span className="type-label-s text-text-primary">{code}</span></span>
            </div>
          </div>
        )}
        <div className="mx-auto mt-4 flex max-w-xl flex-col items-center gap-2 border-t border-border-default pt-4">
          <p className="text-center type-body-s text-text-tertiary">Feil rolle eller lag? Logg ut og bruk lenken eller koden du fikk.</p>
          <button type="button" onClick={onLogout} className="rounded-full border-2 border-border-strong px-4 py-2 type-label-m text-text-danger">
            Logg ut
          </button>
        </div>
      </main>
    </div>
  );
}
