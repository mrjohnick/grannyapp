// Lagets oppgaver: Nabovakten (L3), Rømlingen (L4), Postkort (L5), Poeng (L6).
import { useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase";
import { friendly } from "../lib/errors";
import { formatCountdown, formatGameTime } from "../lib/gameClock";
import { distanceM, distanceText, inZone, zoneCenter } from "../lib/geo";
import type { Coords } from "../lib/hooks";
import type { TeamStatus, Zone } from "../lib/types";
import { Badge, Button, Sheet, TeamDot } from "../components/ui";
import { Icon } from "../components/Icon";
import { CameraCapture, StoredPhoto, uploadPhoto } from "./camera";

const pos = (c: Coords | null) => ({ p_lat: c?.lat ?? null, p_lng: c?.lng ?? null, p_accuracy: c?.accuracy ?? null });

// ---------------------------------------------------------------------------
// Nabovakten
// ---------------------------------------------------------------------------
export function NabovaktSheet({ status, zones, coords, gameS, onClose, onDone }: {
  status: TeamStatus;
  zones: Zone[];
  coords: Coords | null;
  gameS: number;
  onClose: () => void;
  onDone: () => void;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{ hit: boolean; number: number } | null>(null);

  async function checkIn(zoneId: string) {
    setBusy(zoneId);
    setError(null);
    const { data, error } = await supabase.rpc("team_nabovakt", { p_zone: zoneId, ...pos(coords) });
    setBusy(null);
    if (error) return setError(friendly(error));
    setResult(data as { hit: boolean; number: number });
    onDone();
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Nabovakten</h2>
      <p className="type-body-m text-text-secondary">Sjekk inn ved et punkt og få vite om det er en granny innenfor 300 m. Hvert punkt én gang i timen.</p>
      {result && (
        <div className={`flex items-center gap-3 rounded-lg border-2 border-border-strong p-3 ${result.hit ? "bg-bg-success-subtle" : "bg-bg-sunken"}`}>
          <Icon name={result.hit ? "eye" : "eye-off"} size={28} />
          <div>
            <div className="type-label-l">{result.hit ? "Ja, det er en granny innenfor 300 m." : "Nei, ingen grannies her."}</div>
            <div className="type-body-s text-text-secondary">Punkt {result.number}</div>
          </div>
        </div>
      )}
      {status.nabovakt.map((n) => {
        const zone = zones.find((z) => z.id === n.zone_id);
        const center = zone ? zoneCenter(zone) : null;
        const dist = coords && center ? distanceM(coords, center) : null;
        const here = !!zone && inZone(zone, coords);
        const wait = n.next_s != null ? n.next_s - gameS : 0;
        return (
          <div key={n.zone_id} className="flex items-center gap-3 rounded-md border border-border-default bg-bg-surface px-4 py-3">
            <span className="grid size-10 place-items-center rounded-full bg-bg-info-subtle type-label-l">{n.number}</span>
            <div className="flex-1">
              <div className="type-label-l">{n.label}</div>
              <div className="type-body-s text-text-secondary">
                {wait > 0 ? `Brukt. Åpner om ${formatCountdown(wait)}` : here ? "Dere er her" : dist != null ? `${distanceText(dist)} unna` : "Venter på GPS"}
              </div>
            </div>
            <Button size="M" disabled={!here || wait > 0 || busy !== null} onClick={() => checkIn(n.zone_id)}>
              {busy === n.zone_id ? "…" : "Sjekk inn"}
            </Button>
          </div>
        );
      })}
      {status.nabovakt.length === 0 && <p className="type-body-m text-text-secondary">Ingen Nabovakt-punkter i dette spillet.</p>}
      {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Rømlingen
// ---------------------------------------------------------------------------
export function RomlingSheet({ status, zones, coords, gameS, onClose, onDone }: {
  status: TeamStatus;
  zones: Zone[];
  coords: Coords | null;
  gameS: number;
  onClose: () => void;
  onDone: () => void;
}) {
  const [guess, setGuess] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [wrong, setWrong] = useState(false);
  const post = zones.find((z) => z.kind === "nattevakt");
  const here = !!post && inZone(post, coords);
  const center = post ? zoneCenter(post) : null;
  const dist = coords && center ? distanceM(coords, center) : null;
  const wait = status.romling_next_try_s != null ? status.romling_next_try_s - gameS : 0;

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { data, error } = await supabase.rpc("team_romling_guess", { p_guess: guess, ...pos(coords) });
    setBusy(false);
    if (error) return setError(friendly(error));
    const r = data as { correct: boolean };
    setWrong(!r.correct);
    if (r.correct) setGuess("");
    onDone();
  }

  if (status.has_license) {
    return (
      <Sheet onClose={onClose}>
        <Badge tone="success">Lisens</Badge>
        <h2 className="type-display-m">Rømlingen er {status.romling_name}.</h2>
        <p className="type-body-m text-text-secondary">Dere ser navnet hennes på kartet, og kan fange henne for 20p.</p>
      </Sheet>
    );
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Hvem er Rømlingen?</h2>
      <p className="type-body-m text-text-secondary">
        Nattevakten gir dere gåten ved posten. Riktig navn gir 3p og lisens til å fange henne.
      </p>
      {wrong && (
        <div className="rounded-lg border-2 border-border-strong bg-bg-danger-subtle p-3">
          <div className="type-label-l text-text-danger">Feil navn</div>
          <div className="type-body-s">Vis denne skjermen til Nattevakten for del 2 av gåten. Neste forsøk om {formatCountdown(Math.max(wait, 0))}.</div>
        </div>
      )}
      {!here && (
        <div className="flex items-center gap-3 rounded-md bg-bg-warning-subtle p-3">
          <Icon name="moon" />
          <p className="type-body-m">Feltet låses opp ved Nattevaktens post.{dist != null ? ` Dere er ${distanceText(dist)} unna.` : ""}</p>
        </div>
      )}
      <form onSubmit={submit} className="flex flex-col gap-3">
        <input
          value={guess}
          onChange={(e) => setGuess(e.target.value)}
          disabled={!here || wait > 0}
          placeholder="Navnet på Rømlingen"
          autoComplete="off"
          className="h-14 rounded-md border-2 border-border-strong bg-bg-surface px-4 type-body-l disabled:bg-bg-disabled"
        />
        {wait > 0 && !wrong && <p className="type-body-s text-text-secondary">Neste forsøk om {formatCountdown(wait)}.</p>}
        {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
        <Button type="submit" icon="lock" block disabled={!here || wait > 0 || busy || !guess.trim()}>Sjekk navnet</Button>
      </form>
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Postkort
// ---------------------------------------------------------------------------
export function PostkortSheet({ status, gameS, gameId, coords, onClose, onDone }: {
  status: TeamStatus;
  gameS: number;
  gameId: string;
  coords: Coords | null;
  onClose: () => void;
  onDone: (msg: string) => void;
}) {
  const [camera, setCamera] = useState(false);
  const open = status.postcards.find((p) => gameS < p.closes_at_s && !p.won_by);

  async function send(blob: Blob) {
    const path = await uploadPhoto(gameId, blob);
    const { error } = await supabase.rpc("submit_photo", { p_kind: "postkort", p_path: path, ...pos(coords) });
    if (error) throw new Error(friendly(error) ?? "Noe gikk galt.");
    onDone("Postkortet er sendt. Spilleder sjekker at hele laget er med.");
  }

  if (camera && open) {
    return <CameraCapture title={`Postkort ${open.number}`} hint="Hele laget må være med" onSend={send} onClose={() => setCamera(false)} />;
  }

  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Postkort</h2>
      {status.postcards.length === 0 && <p className="type-body-m text-text-secondary">Ingen postkort ennå. Det første kommer 0:30.</p>}
      {status.postcards.map((p) => {
        const isOpen = gameS < p.closes_at_s && !p.won_by;
        return (
          <div key={p.zone_id} className={`flex flex-col gap-2 rounded-lg border-2 p-3 ${isOpen ? "border-border-strong bg-bg-accent-subtle" : "border-border-default bg-bg-surface"}`}>
            <div className="flex items-center justify-between">
              <span className="type-label-caps">Postkort {p.number}</span>
              {p.won_by ? <Badge tone="neutral">{`Tatt av ${p.won_by}`}</Badge>
                : isOpen ? <Badge tone="warning">{`Åpent til ${formatGameTime(p.closes_at_s)}`}</Badge>
                : <Badge tone="neutral">Borte</Badge>}
            </div>
            <p className="type-body-l">{p.mission}</p>
            {p.my_status === "pending" && <p className="type-body-s text-text-secondary">Dere har sendt et bilde. Venter på spilleder.</p>}
            {p.my_status === "rejected" && isOpen && <p className="type-body-s text-text-danger">Forrige bilde ble ikke godkjent. Prøv igjen.</p>}
          </div>
        );
      })}
      {open && (
        <>
          <p className="type-body-s text-text-tertiary">Stedet vises ikke på kartet. Første godkjente bilde gir 2p.</p>
          <Button icon="camera" block onClick={() => setCamera(true)}>Ta gruppebilde</Button>
        </>
      )}
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Poeng og poengtavle
// ---------------------------------------------------------------------------
export function ScoreSheet({ status, teamId, onClose }: { status: TeamStatus; teamId: string; onClose: () => void }) {
  return (
    <Sheet onClose={onClose}>
      <div className="flex items-baseline justify-between">
        <h2 className="type-display-m">Poeng</h2>
        <span className="type-timer-l">{status.points}p</span>
      </div>
      <ol className="flex flex-col gap-1">
        {status.scoreboard.map((t, i) => (
          <li key={t.id} className={`flex items-center gap-3 rounded-md px-3 py-2 ${t.id === teamId ? "bg-bg-brand-subtle" : ""}`}>
            <span className="w-5 type-label-m text-text-tertiary">{i + 1}</span>
            <TeamDot color={t.color} />
            <span className="flex-1 type-label-m">{t.name}</span>
            <span className="type-body-s text-text-secondary">{t.catches} fangst{t.catches === 1 ? "" : "er"}</span>
            <span className="w-12 text-right type-timer-m">{t.points}p</span>
          </li>
        ))}
      </ol>
      {status.album_photos.length > 0 && (
        <>
          <h3 className="type-heading-m">Dere i Fotoalbumet</h3>
          <p className="type-body-s text-text-secondary">Fanger dere fotografen, får dere 2p tilbake.</p>
          {status.album_photos.map((p) => (
            <figure key={p.id} className="overflow-hidden rounded-lg border-2 border-border-strong">
              <StoredPhoto path={p.storage_path} className="aspect-[3/4] w-full object-cover" />
              <figcaption className="px-3 py-2 type-body-s text-text-secondary">Tatt {formatGameTime(p.at_s)}</figcaption>
            </figure>
          ))}
        </>
      )}
    </Sheet>
  );
}

// ---------------------------------------------------------------------------
// Fotoalbumet: bildet vises når blindheten er over
// ---------------------------------------------------------------------------
const seenKey = (teamId: string) => `granny.album.${teamId}`;

function readSeen(teamId: string): string[] {
  try {
    return JSON.parse(localStorage.getItem(seenKey(teamId)) ?? "[]") as string[];
  } catch {
    return [];
  }
}

/** Det nyeste Fotoalbum-bildet laget ikke har sett ennå, eller null. */
export function unseenAlbumPhoto(status: TeamStatus | null, teamId: string) {
  if (!status || status.album_photos.length === 0) return null;
  const seen = readSeen(teamId);
  return status.album_photos.find((p) => !seen.includes(p.id)) ?? null;
}

export function markAlbumSeen(status: TeamStatus, teamId: string) {
  try {
    localStorage.setItem(seenKey(teamId), JSON.stringify(status.album_photos.map((p) => p.id)));
  } catch { /* privat modus */ }
}

export function AlbumRevealSheet({ photo, onClose }: {
  photo: TeamStatus["album_photos"][number];
  onClose: () => void;
}) {
  return (
    <Sheet onClose={onClose}>
      <h2 className="type-display-m">Her er bildet</h2>
      <p className="type-body-m text-text-secondary">
        Dette bildet gjorde dere blinde ved {formatGameTime(photo.at_s)}. Hvem som tok det, får dere vite etter spillet.
      </p>
      <figure className="overflow-hidden rounded-lg border-2 border-border-strong">
        <StoredPhoto path={photo.storage_path} className="aspect-[3/4] w-full object-cover" />
      </figure>
      <Button block onClick={onClose}>Videre</Button>
    </Sheet>
  );
}
