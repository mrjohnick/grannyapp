// Grannyens oppgaver: taxi og Sladrehanken. Oppdrag ligger i features/quests.
import { useState } from "react";
import { supabase } from "../lib/supabase";
import { friendly } from "../lib/errors";
import { formatCountdown } from "../lib/gameClock";
import type { Coords } from "../lib/hooks";
import type { GrannyStatus } from "../lib/types";
import { Badge, Button, Initial, SelectRow, Sheet } from "../components/ui";
import { Icon } from "../components/Icon";
import { Avatar } from "../components/Avatar";

const pos = (c: Coords | null) => ({ p_lat: c?.lat ?? null, p_lng: c?.lng ?? null, p_accuracy: c?.accuracy ?? null });

export function GrannyPoints({ status, isRomling }: { status: GrannyStatus | null; isRomling: boolean }) {
  if (!status) return null;
  const left = Math.max(0, status.taxi_max_rides - status.taxi_rides);
  return (
    <div className="flex items-center gap-2 rounded-full border-2 border-border-strong bg-bg-surface px-3 py-1 shadow-md">
      {!isRomling && <span className="type-label-m">{status.points}p</span>}
      <span className="flex items-center gap-1 type-body-s text-text-secondary">
        <Icon name="taxi" size={16} /> {left > 0 ? `${left} taxitur igjen` : "Taxi brukt"}
      </span>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Taxi: bestill, så tar første ledige sjåfør turen
// ---------------------------------------------------------------------------
const TAXI_TEXT = {
  waiting: "Venter på en ledig sjåfør.",
  accepted: "kommer og henter deg.",
  picked_up: "Du sitter i taxien.",
} as const;

export function TaxiSheet({ status, coords, gameS, caught, taxisOnline, onClose, onDone }: {
  status: GrannyStatus;
  coords: Coords | null;
  gameS: number;
  /** Fanget: turen teller ikke, men hun står sist i køen. */
  caught: boolean;
  /** Taxier som har sendt posisjon de siste 5 minuttene (fra granny_map). */
  taxisOnline: number;
  onClose: () => void;
  onDone: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const req = status.taxi_request;
  const used = !caught && status.taxi_rides >= status.taxi_max_rides;
  // taxi_rides er brukte turer minus ekstra turer fra spilleder.
  const left = Math.max(0, status.taxi_max_rides - status.taxi_rides);

  async function call(fn: string, args: Record<string, unknown> = {}) {
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) return setError(friendly(error));
    onDone();
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Taxi</h2>
      {caught ? (
        <p className="type-body-m text-text-secondary">
          Du er fanget, men kan få skyss. Du står sist i køen, bak alle som fortsatt er med i jakten.
        </p>
      ) : (
        <p className="type-body-m text-text-secondary">
          Du har {left === 1 ? "én taxitur" : `${left} taxiturer`} igjen. Taxiene ser du på kartet.
          Når du blir hentet, får alle lag vite at du har tatt taxi, men ikke hvor.
        </p>
      )}
      {req ? (
        <div className="flex flex-col gap-2 rounded-md bg-bg-warning-subtle p-3">
          <span className="type-label-l">
            {req.status === "accepted" ? `${req.taxi_name ?? "Taxien"} ${TAXI_TEXT.accepted}` : TAXI_TEXT[req.status]}
          </span>
          {req.status === "waiting" && req.queue_position != null && (
            <span className="type-body-s">Du er nr. {req.queue_position} i køen{req.last_in_queue ? " (fanget: bak de andre)" : ""}.</span>
          )}
          {req.status === "picked_up" && req.ride_ends_s != null && (
            <span className={`type-timer-l ${req.ride_ends_s - gameS <= 60 ? "text-text-danger" : ""}`}>
              {formatCountdown(Math.max(0, req.ride_ends_s - gameS))} igjen i taxien
            </span>
          )}
        </div>
      ) : (
        <Badge tone={used ? "warning" : "success"}>{used ? "Du har brukt taxituren din" : "Taxituren er ubrukt"}</Badge>
      )}
      {status.taxis === 0 && <p className="type-body-s text-text-warning">Det er ingen taxier i spillet ennå.</p>}
      {status.taxis > 0 && taxisOnline === 0 && (!req || req.status === "waiting") && (
        <p className="rounded-md bg-bg-warning-subtle p-3 type-body-s">
          Ingen taxi er på nett akkurat nå. Du kan bestille likevel og står da i kø til en sjåfør åpner appen.
        </p>
      )}
      {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
      {req && req.status !== "picked_up" ? (
        <Button variant="secondary" block disabled={busy} onClick={() => confirm("Avbestille taxien?") && call("granny_cancel_taxi")}>Avbestill</Button>
      ) : !req ? (
        <Button icon="taxi" block disabled={busy || used || status.taxis === 0} onClick={() => call("granny_request_taxi", pos(coords))}>Bestill taxi</Button>
      ) : null}
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Sladrehanken
// ---------------------------------------------------------------------------
export function SnitchSheet({ status, coords, avatarOf, onClose, onDone }: {
  status: GrannyStatus;
  coords: Coords | null;
  avatarOf: (grannyId: string | null | undefined) => string | null;
  onClose: () => void;
  onDone: (s: GrannyStatus) => void;
}) {
  const [target, setTarget] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const chosen = status.targets.find((t) => t.id === target);

  async function snitch() {
    if (!target) return;
    setBusy(true);
    setError(null);
    const { data, error } = await supabase.rpc("granny_snitch", { p_target: target, ...pos(coords) });
    setBusy(false);
    if (error) return setError(friendly(error));
    onDone(data as GrannyStatus);
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Sladrehanken</h2>
      <p className="type-body-m text-text-secondary">
        Du kan sladre én gang i løpet av spillet, på hvem du vil. Alle lag ser da hvor hun er akkurat nå, som en ekstra ping.
        Det gir ingen poeng. Ingen får vite at det var deg før oppsummeringen.
      </p>
      {status.snitch_used ? (
        <p className="rounded-md bg-bg-sunken p-3 type-body-m">Du har brukt sladringen din.</p>
      ) : (
        <>
          {status.targets.length === 0 && <p className="type-body-m text-text-secondary">Ingen andre er fri.</p>}
          {status.targets.map((t) => (
            <SelectRow key={t.id} title={t.name}
              lead={avatarOf(t.id) ? <Avatar name={t.name} url={avatarOf(t.id)} /> : <Initial name={t.name} />}
              selected={t.id === target} onClick={() => setTarget(t.id)} />
          ))}
        </>
      )}
      {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
      {!status.snitch_used && (
        <Button icon="megaphone" block disabled={!chosen || busy} onClick={snitch}>
          {chosen ? `Sladre på ${chosen.name}` : "Velg hvem du sladrer på"}
        </Button>
      )}
    </Sheet>
  );
}
