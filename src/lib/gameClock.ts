// Spillklokke og ping-tider. Ren logikk, ingen React – testes i gameClock.test.ts.

/** 4062 → "1:07:42" */
export function formatClock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}

/** 438 → "7:18", 3725 → "1:02:05" */
export function formatCountdown(seconds: number): string {
  const s = Math.max(0, Math.ceil(seconds));
  if (s >= 3600) return formatClock(s);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/** 2700 → "0:45" (spilltid uten sekunder, slik specen skriver det) */
export function formatGameTime(seconds: number): string {
  const m = Math.floor(seconds / 60);
  return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, "0")}`;
}

export function lastPing(schedule: number[], s: number): number | null {
  let last: number | null = null;
  for (const p of schedule) if (p <= s) last = p;
  return last;
}

export function nextPing(schedule: number[], s: number): number | null {
  for (const p of schedule) if (p > s) return p;
  return null;
}

export type ClockSnapshot = {
  status: "setup" | "running" | "paused" | "ended";
  game_s: number;
  duration_s: number;
  /** Serverens klokke da snapshot ble laget (ISO). */
  server_time: string;
};

/**
 * Spilltid nå, regnet ut lokalt fra et snapshot fra serveren.
 * `fetchedAt` er klientens Date.now() da svaret kom; avviket mellom
 * klient- og serverklokke påvirker derfor ikke resultatet.
 */
export function currentGameSeconds(snap: ClockSnapshot, fetchedAt: number, now = Date.now()): number {
  if (snap.status !== "running") return snap.game_s;
  const elapsed = (now - fetchedAt) / 1000;
  return Math.min(snap.duration_s, snap.game_s + Math.max(0, elapsed));
}
