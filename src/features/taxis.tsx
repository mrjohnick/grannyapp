// Spilleder: taxiturer som pågår, og taxiturer per granny. Her kan spilleder
// avbryte en tur, sende en annen taxi, angre en henting og gi ekstra turer.
import { useCallback, useEffect, useState } from "react";
import { supabase } from "../lib/supabase";
import { friendly } from "../lib/errors";
import { useInterval } from "../lib/hooks";
import { useEventVersion } from "../lib/events";
import { formatCountdown } from "../lib/gameClock";
import { Badge, Button } from "../components/ui";

type Overview = {
  max_rides: number;
  requests: Array<{
    id: string;
    status: "waiting" | "accepted" | "picked_up";
    granny_id: string;
    granny_name: string;
    caught: boolean;
    ride_ends_s: number | null;
    taxi_id: string | null;
    taxi_name: string | null;
    requested_s: number;
    accepted_s: number | null;
    picked_s: number | null;
    driver_quiet_s: number | null;
  }>;
  grannies: Array<{ id: string; name: string; is_romling: boolean; caught: boolean; rides: number; extra: number }>;
  online: string[];
};

const STATUS: Record<Overview["requests"][number]["status"], [string, "warning" | "brand" | "success"]> = {
  waiting: ["I kø", "warning"],
  accepted: ["På vei", "brand"],
  picked_up: ["I bilen", "success"],
};

export function AdminTaxis({ taxiCount, gameS }: { taxiCount: number; gameS: number }) {
  const { version } = useEventVersion();
  const [data, setData] = useState<Overview | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("admin_taxi_overview");
    if (!error && data) setData(data as Overview);
  }, []);
  useInterval(load, 5000);
  useEffect(() => { load(); }, [version, load]);

  async function run(key: string, fn: string, args: Record<string, unknown>, question?: string) {
    if (question && !confirm(question)) return;
    setBusy(key);
    setError(null);
    const { error } = await supabase.rpc(fn, args);
    setBusy(null);
    if (error) setError(friendly(error));
    load();
  }

  if (!data || taxiCount === 0) return null;
  const action = (id: string, a: string, question: string) => run(`${id}-${a}`, "admin_taxi_action", { p_request: id, p_action: a }, question);

  return (
    <section className="flex flex-col gap-2 rounded-lg border border-border-default bg-bg-surface p-3">
      <div className="flex items-baseline justify-between gap-2">
        <h2 className="type-heading-m">Taxi</h2>
        <span className={`type-label-s ${data.online.length === 0 ? "text-text-danger" : "text-text-secondary"}`}>
          {data.online.length} av {taxiCount} på nett
        </span>
      </div>
      {error && <p className="rounded-md bg-bg-danger-subtle p-2 type-body-s text-text-danger">{error}</p>}

      {data.requests.length === 0 ? (
        <p className="type-body-s text-text-tertiary">Ingen taxiturer akkurat nå.</p>
      ) : (
        <ul className="flex flex-col gap-2">
          {data.requests.map((r) => {
            const [label, tone] = STATUS[r.status];
            const quiet = r.driver_quiet_s ?? 0;
            return (
              <li key={r.id} className="flex flex-col gap-2 rounded-md border border-border-default p-2">
                <div className="flex items-center gap-2">
                  <span className="flex-1 type-label-m">
                    {r.granny_name}{r.caught && <span className="type-body-s text-text-tertiary"> · fanget, sist i køen</span>}
                  </span>
                  <Badge tone={tone}>{label}</Badge>
                </div>
                <p className="type-body-s text-text-secondary">
                  {r.status === "waiting" && `Har ventet ${formatCountdown(Math.max(0, gameS - r.requested_s))}`}
                  {r.status === "accepted" && `${r.taxi_name ?? "Taxi"} er på vei`}
                  {r.status === "picked_up" && `Sitter i ${r.taxi_name ?? "taxien"}`}
                  {r.status === "picked_up" && r.ride_ends_s != null && ` · ${formatCountdown(Math.max(0, r.ride_ends_s - gameS))} igjen`}
                </p>
                {r.status === "accepted" && quiet >= 60 && (
                  <p className="rounded-sm bg-bg-warning-subtle px-2 py-1 type-body-s">
                    Sjåføren har ikke sendt posisjon på {Math.round(quiet / 60)} min.
                  </p>
                )}
                <div className="flex flex-wrap gap-2">
                  {r.status === "accepted" && (
                    <Button size="M" variant="secondary" disabled={busy !== null}
                      onClick={() => action(r.id, "requeue", `Sende en annen taxi til ${r.granny_name}? Hun står først i køen.`)}>
                      Send annen taxi
                    </Button>
                  )}
                  {r.status === "picked_up" && (
                    <Button size="M" variant="secondary" disabled={busy !== null}
                      onClick={() => action(r.id, "undo_pickup", `Angre hentingen av ${r.granny_name}? Turen hennes regnes som ubrukt, og hentestedet fjernes fra lagenes kart.`)}>
                      Angre henting
                    </Button>
                  )}
                  <Button size="M" variant="secondary" disabled={busy !== null}
                    onClick={() => action(r.id, "cancel", r.status === "picked_up"
                      ? `Avslutte turen til ${r.granny_name}? Hun regnes som levert.`
                      : `Avbryte taxien til ${r.granny_name}?`)}>
                    {r.status === "picked_up" ? "Avslutt" : "Avbryt"}
                  </Button>
                </div>
              </li>
            );
          })}
        </ul>
      )}

      <details className="rounded-md border border-border-default p-2">
        <summary className="cursor-pointer type-label-m">Taxiturer per granny</summary>
        <ul className="mt-2 flex flex-col gap-1">
          {data.grannies.map((g) => {
            const allowed = data.max_rides + g.extra;
            return (
              <li key={g.id} className="flex items-center gap-2 type-body-s">
                <span className={`flex-1 truncate ${g.caught ? "text-text-tertiary line-through" : ""}`}>
                  {g.name}{g.is_romling ? " (Rømling)" : ""}
                </span>
                <span className={g.rides >= allowed ? "text-text-tertiary" : "text-text-success"}>
                  {g.rides} av {allowed} brukt
                </span>
                {g.extra > 0 && (
                  <button type="button" className="rounded-full border border-border-strong px-2 type-label-s" disabled={busy !== null}
                    aria-label={`Ta tilbake en ekstra tur fra ${g.name}`}
                    onClick={() => run(`${g.id}-minus`, "admin_taxi_extra_ride", { p_granny: g.id, p_delta: -1 })}>
                    −
                  </button>
                )}
                <button type="button" className="rounded-full border border-border-strong px-2 type-label-s" disabled={busy !== null}
                  aria-label={`Gi ${g.name} en ekstra taxitur`}
                  onClick={() => run(`${g.id}-plus`, "admin_taxi_extra_ride", { p_granny: g.id, p_delta: 1 }, `Gi ${g.name} en ekstra taxitur?`)}>
                  +1 tur
                </button>
              </li>
            );
          })}
        </ul>
      </details>
    </section>
  );
}
