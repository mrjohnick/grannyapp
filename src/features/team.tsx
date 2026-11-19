// Lagets oppgaver: Postkort (L5) og Poeng (L6).
import { useState } from "react";
import { supabase } from "../lib/supabase";
import { friendly } from "../lib/errors";
import { formatGameTime } from "../lib/gameClock";
import type { Coords } from "../lib/hooks";
import type { TeamStatus } from "../lib/types";
import { Badge, Button, Sheet, TeamDot } from "../components/ui";
import { CameraCapture, StoredPhoto, uploadPhoto } from "./camera";

const pos = (c: Coords | null) => ({ p_lat: c?.lat ?? null, p_lng: c?.lng ?? null, p_accuracy: c?.accuracy ?? null });

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
