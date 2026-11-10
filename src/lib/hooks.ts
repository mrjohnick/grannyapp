import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "./supabase";
import { currentGameSeconds } from "./gameClock";
import type { GameState } from "./types";

/** Henter spilltilstand fra serveren og teller klokka lokalt mellom hentingene. */
export function useGameState(refreshMs = 20_000) {
  const [state, setState] = useState<GameState | null>(null);
  const [fetchedAt, setFetchedAt] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [now, setNow] = useState(Date.now());

  const refresh = useCallback(async () => {
    const { data, error } = await supabase.rpc("game_state");
    setLoaded(true);
    if (error) return setError(error.message);
    setError(null);
    setState(data as GameState | null);
    setFetchedAt(Date.now());
  }, []);

  useEffect(() => {
    refresh();
    const poll = setInterval(refresh, refreshMs);
    const tick = setInterval(() => setNow(Date.now()), 250);
    const onVisible = () => document.visibilityState === "visible" && refresh();
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      clearInterval(poll);
      clearInterval(tick);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [refresh, refreshMs]);

  const gameS = state ? currentGameSeconds(state, fetchedAt, now) : 0;
  return { state, gameS, error, loaded, refresh };
}

/** Kjører `fn` hver gang spilltiden passerer et nytt ping. */
export function useOnPing(schedule: number[] | undefined, gameS: number, fn: () => void) {
  const last = useRef<number | null | undefined>(undefined);
  useEffect(() => {
    if (!schedule) return;
    let current: number | null = null;
    for (const p of schedule) if (p <= gameS) current = p;
    if (last.current === undefined) {
      // Første måling: husk hvor vi er, men ikke meld et ping som skjedde før siden ble åpnet.
      last.current = current;
      return;
    }
    if (current !== last.current) {
      last.current = current;
      fn();
    }
  }, [schedule, gameS, fn]);
}

export type Coords = { lat: number; lng: number; accuracy: number };

/**
 * Følger enhetens GPS mens siden er åpen og sender posisjonen til serveren
 * høyst hvert `sendEveryMs`. For grannies er dette bare en reserve: pingene
 * bruker Telegram. Appens posisjon brukes til sonesjekk ved handlinger.
 */
export function useDevicePosition(enabled: boolean, sendEveryMs = 15_000) {
  const [coords, setCoords] = useState<Coords | null>(null);
  const [error, setError] = useState<string | null>(null);
  const lastSent = useRef(0);

  useEffect(() => {
    if (!enabled) return;
    if (!("geolocation" in navigator)) {
      setError("Telefonen støtter ikke posisjon.");
      return;
    }
    const id = navigator.geolocation.watchPosition(
      (pos) => {
        const c = { lat: pos.coords.latitude, lng: pos.coords.longitude, accuracy: pos.coords.accuracy };
        setCoords(c);
        setError(null);
        if (Date.now() - lastSent.current >= sendEveryMs) {
          lastSent.current = Date.now();
          supabase.rpc("report_position", { p_lat: c.lat, p_lng: c.lng, p_accuracy: c.accuracy }).then(({ error }) => {
            if (error) console.warn("report_position", error.message);
          });
        }
      },
      (err) =>
        setError(
          err.code === err.PERMISSION_DENIED
            ? "Du har ikke gitt tilgang til posisjon. Slå det på i nettleserinnstillingene."
            : "Fant ikke posisjonen din. Gå ut i det fri.",
        ),
      { enableHighAccuracy: true, maximumAge: 5_000, timeout: 20_000 },
    );
    return () => navigator.geolocation.clearWatch(id);
  }, [enabled, sendEveryMs]);

  return { coords, error };
}

/** Holder skjermen våken mens siden er synlig (der nettleseren støtter det). */
export function useWakeLock(enabled: boolean) {
  useEffect(() => {
    if (!enabled || !("wakeLock" in navigator)) return;
    let lock: WakeLockSentinel | null = null;
    const acquire = async () => {
      try {
        lock = await navigator.wakeLock.request("screen");
      } catch {
        /* f.eks. lavt batteri – ikke kritisk */
      }
    };
    const onVisible = () => document.visibilityState === "visible" && acquire();
    acquire();
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      document.removeEventListener("visibilitychange", onVisible);
      lock?.release().catch(() => {});
    };
  }, [enabled]);
}

/** Kaller `fn` nå og deretter hvert `ms`. */
export function useInterval(fn: () => void, ms: number, enabled = true) {
  const saved = useRef(fn);
  saved.current = fn;
  useEffect(() => {
    if (!enabled) return;
    saved.current();
    const id = setInterval(() => saved.current(), ms);
    return () => clearInterval(id);
  }, [ms, enabled]);
}
