// Grannyens oppgaver: taxi, Sladrehanken, Fotoalbumet og Bingo (G2–G4).
import { useState } from "react";
import { supabase } from "../lib/supabase";
import { friendly } from "../lib/errors";
import { formatCountdown, formatGameTime } from "../lib/gameClock";
import type { Coords } from "../lib/hooks";
import type { GrannyStatus } from "../lib/types";
import { Badge, Button, Initial, SelectRow, Sheet, TeamDot } from "../components/ui";
import { Icon } from "../components/Icon";
import { CameraCapture, uploadPhoto } from "./camera";

const pos = (c: Coords | null) => ({ p_lat: c?.lat ?? null, p_lng: c?.lng ?? null, p_accuracy: c?.accuracy ?? null });

export function GrannyPoints({ status, isRomling }: { status: GrannyStatus | null; isRomling: boolean }) {
  if (!status) return null;
  const left = status.honnor_max_rides - status.taxi_rides;
  return (
    <div className="flex items-center gap-2 rounded-full border-2 border-border-strong bg-bg-surface px-3 py-1 shadow-md">
      {!isRomling && <span className="type-label-m">{status.points}p</span>}
      <span className="flex items-center gap-1 type-body-s text-text-secondary">
        <Icon name="taxi" size={16} /> {status.taxi_rides}
        {!isRomling && (left >= 0 ? ` · Honnør: ${left} igjen` : " · Honnør ryket")}
      </span>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Taxi
// ---------------------------------------------------------------------------
export function TaxiSheet({ status, gameS, coords, isRomling, onClose, onDone }: {
  status: GrannyStatus;
  gameS: number;
  coords: Coords | null;
  isRomling: boolean;
  onClose: () => void;
  onDone: (s: GrannyStatus) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const wait = status.next_taxi_s != null ? status.next_taxi_s - gameS : 0;
  const ridesAfter = status.taxi_rides + 1;
  const losesHonnor = !isRomling && ridesAfter > status.honnor_max_rides && status.taxi_rides <= status.honnor_max_rides;

  async function register() {
    setBusy(true);
    setError(null);
    const { data, error } = await supabase.rpc("granny_taxi", pos(coords));
    setBusy(false);
    if (error) return setError(friendly(error));
    onDone(data as GrannyStatus);
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Ta taxi</h2>
      <p className="type-body-m text-text-secondary">
        Ring sjåføren og registrer turen når du sitter i bilen. Lagene får beskjed om at en granny har tatt taxi, men ikke hvem.
      </p>
      <div className="flex gap-2">
        <Badge tone="neutral">{`${status.taxi_rides} ${status.taxi_rides === 1 ? "tur" : "turer"} så langt`}</Badge>
        {!isRomling && <Badge tone={losesHonnor ? "warning" : "success"}>{`Honnørrabatt: maks ${status.honnor_max_rides}`}</Badge>}
      </div>
      {losesHonnor && <p className="rounded-md bg-bg-warning-subtle p-3 type-body-s">Dette er tur nr. {ridesAfter}. Da mister du Honnørrabatten (3p).</p>}
      {wait > 0 && (
        <p className="rounded-md bg-bg-sunken p-3 type-body-m">
          Neste taxi om <span className="type-timer-m">{formatCountdown(wait)}</span>.
        </p>
      )}
      {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
      <Button icon="taxi" block disabled={busy || wait > 0} onClick={register}>Registrer taxitur</Button>
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Sladrehanken
// ---------------------------------------------------------------------------
export function SnitchSheet({ status, coords, inKaffekroken, distanceText, onClose, onDone }: {
  status: GrannyStatus;
  coords: Coords | null;
  inKaffekroken: boolean;
  distanceText: string | null;
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
        Den du velger, vises live hos alle lag i 60 sekunder. Fanges hun innen 10 minutter, får du 3p. Ingen får vite at det var deg før oppsummeringen.
      </p>
      {status.snitch_used ? (
        <p className="rounded-md bg-bg-sunken p-3 type-body-m">Du har brukt sladringen din.</p>
      ) : !inKaffekroken ? (
        <div className="flex items-center gap-3 rounded-md bg-bg-warning-subtle p-3">
          <Icon name="coffee" />
          <p className="type-body-m">Gå til Kaffekroken for å sladre.{distanceText ? ` Du er ${distanceText} unna.` : ""}</p>
        </div>
      ) : (
        <>
          {status.targets.length === 0 && <p className="type-body-m text-text-secondary">Ingen andre er fri.</p>}
          {status.targets.map((t) => (
            <SelectRow key={t.id} title={t.name} lead={<Initial name={t.name} />} selected={t.id === target} onClick={() => setTarget(t.id)} />
          ))}
          <p className="type-body-s text-text-tertiary">Lagene ser en grå markør i Kaffekroken når du sladrer.</p>
        </>
      )}
      {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
      {!status.snitch_used && inKaffekroken && (
        <Button icon="megaphone" block disabled={!chosen || busy} onClick={snitch}>
          {chosen ? `Sladre på ${chosen.name}` : "Velg hvem du sladrer på"}
        </Button>
      )}
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Fotoalbumet og Bingo
// ---------------------------------------------------------------------------
export function PhotoSheet({ status, gameS, gameId, coords, inBingo, onClose, onDone }: {
  status: GrannyStatus;
  gameS: number;
  gameId: string;
  coords: Coords | null;
  inBingo: boolean;
  onClose: () => void;
  onDone: (message: string) => void;
}) {
  const [mode, setMode] = useState<"fotoalbum" | "bingo" | null>(null);
  const [team, setTeam] = useState<string | null>(null);
  const [camera, setCamera] = useState(false);
  const albumWait = status.fotoalbum_next_s != null ? status.fotoalbum_next_s - gameS : 0;
  const albumOpen = albumWait <= 0;
  const bingoOpen = !status.bingo_done && inBingo;

  async function send(blob: Blob) {
    const path = await uploadPhoto(gameId, blob);
    const { error } = await supabase.rpc("submit_photo", {
      p_kind: mode, p_path: path, ...pos(coords), p_target_team: mode === "fotoalbum" ? team : null,
    });
    if (error) throw new Error(friendly(error) ?? "Noe gikk galt.");
    onDone(mode === "bingo" ? `Bingo! Du får ${status.bingo_points_next}p.` : "Bildet er sendt. Spilleder godkjenner det.");
  }

  if (camera && mode) {
    return (
      <CameraCapture
        title={mode === "bingo" ? "Bingo" : "Fotoalbumet"}
        hint={mode === "bingo" ? "Ta bildet mens du står i sonen" : "Lagfargen må synes på bildet"}
        onSend={send}
        onClose={() => setCamera(false)}
      />
    );
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Ta bilde</h2>
      <SelectRow
        title="Fotoalbumet"
        subtitle={albumOpen ? "2p. Laget blir blindet i 10 min." : status.fotoalbum_pending ? "Venter på spilleder" : `Åpner igjen om ${formatCountdown(albumWait)}`}
        lead={<span className="grid size-10 place-items-center rounded-full bg-bg-brand-subtle"><Icon name="camera" /></span>}
        selected={mode === "fotoalbum"}
        disabled={!albumOpen}
        onClick={() => setMode("fotoalbum")}
      />
      <SelectRow
        title="Bingo"
        subtitle={status.bingo_done ? "Du har tatt Bingo" : inBingo ? `${status.bingo_points_next}p nå` : "Gå til Bingo-sonen"}
        lead={<span className="grid size-10 place-items-center rounded-full bg-bg-brand-subtle"><Icon name="bingo" /></span>}
        selected={mode === "bingo"}
        disabled={!bingoOpen}
        onClick={() => setMode("bingo")}
      />
      {mode === "bingo" && <p className="type-body-s text-text-secondary">Lagene får posisjonen din, men aldri bildet.</p>}
      {mode === "fotoalbum" && (
        <>
          <h3 className="type-heading-s">Hvilket lag er på bildet?</h3>
          <div className="flex flex-wrap gap-2">
            {status.teams.map((t) => (
              <button
                key={t.id}
                type="button"
                onClick={() => setTeam(t.id === team ? null : t.id)}
                className={`flex items-center gap-2 rounded-full border-2 px-3 py-2 type-label-s ${t.id === team ? "border-border-brand bg-bg-brand-subtle" : "border-border-default bg-bg-surface"}`}
              >
                <TeamDot color={t.color} /> {t.name}
              </button>
            ))}
          </div>
          <p className="type-body-s text-text-tertiary">Usikker? Hopp over. Spilleder setter laget ved godkjenning.</p>
        </>
      )}
      <Button icon="camera" block disabled={!mode} onClick={() => setCamera(true)}>Åpne kamera</Button>
      {status.fotoalbum_next_s != null && albumOpen && (
        <p className="type-body-s text-text-tertiary">Forrige bilde til Fotoalbumet: {formatGameTime(status.fotoalbum_next_s - 3600)}.</p>
      )}
    </Sheet>
  );
}
