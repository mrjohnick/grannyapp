// Lagets poeng og poengtavle (L6), og Fotoalbum-bilder fra tidligere runder.
import { formatGameTime } from "../lib/gameClock";
import type { TeamStatus } from "../lib/types";
import { Button, Sheet, TeamDot } from "../components/ui";
import { StoredPhoto } from "./camera";

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
// Fotoalbumet: laget får se bildet de ble tatt med i (én gang per bilde)
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
        Dere ble tatt med i Fotoalbumet ved {formatGameTime(photo.at_s)} og mistet 2p. Hvem som tok bildet, får dere vite etter spillet.
      </p>
      <figure className="overflow-hidden rounded-lg border-2 border-border-strong">
        <StoredPhoto path={photo.storage_path} className="aspect-[3/4] w-full object-cover" />
      </figure>
      <Button block onClick={onClose}>Videre</Button>
    </Sheet>
  );
}
