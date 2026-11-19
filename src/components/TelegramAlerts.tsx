// Varsler i Telegram. Hver telefon kobler seg til boten med sin egen lenke
// (my_telegram_alerts). game-worker sender deretter de samme varslene som
// push, og Telegram viser dem også når mobilen er låst.
import { useCallback, useEffect, useState } from "react";
import { supabase } from "../lib/supabase";
import { useInterval } from "../lib/hooks";
import { Icon } from "./Icon";

export const TELEGRAM_BOT = (import.meta.env.VITE_TELEGRAM_BOT_USERNAME as string | undefined) ?? "GrannyBot";

type Status = { link_token: string; linked: boolean; last_position_age_s?: number | null };

function useTelegramAlerts() {
  const [status, setStatus] = useState<Status | null>(null);
  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("my_telegram_alerts");
    if (!error && data) setStatus(data as Status);
  }, []);
  // Sjekk på nytt når brukeren kommer tilbake fra Telegram.
  useEffect(() => {
    const onVisible = () => document.visibilityState === "visible" && load();
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [load]);
  useInterval(load, 30_000);
  return status;
}

const link = (s: Status) => `https://t.me/${TELEGRAM_BOT}?start=${s.link_token}`;

/** Liten knapp ved siden av PushChip. Skjules når telefonen er koblet. */
export function TelegramChip() {
  const status = useTelegramAlerts();
  if (!status || status.linked) return null;
  return (
    <a
      href={link(status)}
      target="_blank"
      rel="noreferrer"
      className="flex items-center gap-1 rounded-full border border-border-strong bg-bg-surface px-3 py-1 type-label-s"
    >
      <Icon name="send" size={16} /> Få varsler i Telegram
    </a>
  );
}

/** Øverst på varslingssiden: viser om varslene også går til Telegram. */
export function TelegramBanner() {
  const status = useTelegramAlerts();
  if (!status) return null;
  if (status.linked) {
    return (
      <p className="mx-auto mb-3 flex max-w-xl items-center gap-2 rounded-md bg-bg-success-subtle px-3 py-2 type-body-s">
        <Icon name="check" size={16} /> Varslene kommer også i Telegram. Skriv /stopp til boten for å slå dem av.
      </p>
    );
  }
  return (
    <div className="mx-auto mb-3 flex max-w-xl flex-col gap-2 rounded-lg border-2 border-border-strong bg-bg-warning-subtle p-3">
      <p className="type-body-s">Få varslene i Telegram også. Da kommer de fram selv om mobilen er låst.</p>
      <a
        href={link(status)}
        target="_blank"
        rel="noreferrer"
        className="flex items-center justify-center gap-2 rounded-full border-2 border-border-strong bg-bg-surface px-4 py-2 type-label-m"
      >
        <Icon name="send" size={18} /> Koble til Telegram
      </a>
    </div>
  );
}

type Count = { phones: number; telegram: number };
type AdminAlerts = {
  teams: Array<{ id: string; name: string; color: string } & Count>;
  taxis: Array<{ id: string; name: string } & Count>;
  grannies: { total: number; telegram: number };
  admins: Count;
};

/** Spilleder: hvor mange telefoner per lag som får varsler i Telegram. */
export function AdminTelegramAlerts() {
  const [data, setData] = useState<AdminAlerts | null>(null);
  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("admin_telegram_alerts");
    if (!error && data) setData(data as AdminAlerts);
  }, []);
  useInterval(load, 15_000);
  if (!data) return null;

  const rows: Array<[string, number, number]> = [
    ...data.teams.map((t) => [t.name, t.telegram, t.phones] as [string, number, number]),
    ...data.taxis.map((x) => [x.name, x.telegram, x.phones] as [string, number, number]),
    ["Grannies", data.grannies.telegram, data.grannies.total],
    ["Spilledere", data.admins.telegram, data.admins.phones],
  ];
  return (
    <section className="rounded-lg border border-border-default bg-bg-surface p-3">
      <h2 className="type-heading-m">Varsler i Telegram</h2>
      <p className="mb-2 type-body-s text-text-tertiary">Telefoner som får varslene i Telegram. Grannies telles per granny.</p>
      <ul className="flex flex-col gap-1">
        {rows.map(([name, on, all]) => (
          <li key={name} className="flex items-center gap-2 type-body-s">
            <span className="flex-1 truncate">{name}</span>
            <span className={`type-label-s ${on === 0 ? "text-text-danger" : on < all ? "text-text-secondary" : "text-text-success"}`}>
              {on} av {all}
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

/**
 * Taxi: koble til boten og del live-posisjon der. Da ser grannyene taxien
 * også når appen er lukket eller sjåføren bruker et navigasjonsprogram.
 */
export function TaxiTelegramCard() {
  const status = useTelegramAlerts();
  if (!status) return null;
  const age = status.last_position_age_s;
  const live = status.linked && age != null && age < 120;
  if (live) {
    return (
      <span className="flex items-center gap-1 rounded-full border border-border-strong bg-bg-success-subtle px-3 py-1 type-label-s">
        <Icon name="send" size={16} /> Telegram live · {age} s
      </span>
    );
  }
  return (
    <a href={status.linked ? `https://t.me/${TELEGRAM_BOT}` : link(status)} target="_blank" rel="noreferrer"
      className="flex w-full max-w-sm items-center gap-3 rounded-lg border-2 border-border-strong bg-bg-warning p-3 shadow-hard">
      <Icon name="send" size={24} />
      <span className="flex-1">
        <span className="block type-label-m">{status.linked ? "Del live-posisjon i Telegram" : "Koble til Telegram"}</span>
        <span className="block type-body-s">
          {status.linked
            ? "I chatten med boten: ⊕ → Posisjon → «Del live-posisjon» → «Til jeg slår det av». Da ser grannyene deg selv når appen er lukket."
            : "Få varsler og del posisjonen med boten, så grannyene ser taxien selv når appen er lukket."}
        </span>
      </span>
    </a>
  );
}
