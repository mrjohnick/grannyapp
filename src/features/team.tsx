// Lagets oppgaver: Postkort (L5) og Poeng (L6).
import { useState } from "react";
import { supabase } from "../lib/supabase";
import { friendly } from "../lib/errors";
import { formatGameTime } from "../lib/gameClock";
import type { Coords } from "../lib/hooks";
import type { TeamStatus } from "../lib/types";
import { Badge, Button, Sheet, TeamDot } from "../components/ui";
import { StoredPhoto } from "./camera";

const pos = (c: Coords | null) => ({ p_lat: c?.lat ?? null, p_lng: c?.lng ?? null, p_accuracy: c?.accuracy ?? null });

// ---------------------------------------------------------------------------
// Postkort
// ---------------------------------------------------------------------------
export function PostkortSheet({ status, gameS, coords, onClose, onDone }: {
  status: TeamStatus;
  gameS: number;
  coords: Coords | null;
  onClose: () => void;
  onDone: (msg: string) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const open = status.postcards.find((p) => gameS < p.closes_at_s && !p.won_by);

  async function deliver() {
    if (!confirm("Marker postkortet som levert? Send gruppebildet i lagets Telegram-gruppe først.")) return;
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc("deliver_postkort", pos(coords));
    setBusy(false);
    if (error) return setError(friendly(error) ?? "Noe gikk galt.");
    onDone("Postkortet er levert. Spilleder sjekker bildet i Telegram.");
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
            {p.my_status === "pending" && <p className="type-body-s text-text-secondary">Levert. Venter på spilleder.</p>}
            {p.my_status === "rejected" && isOpen && <p className="type-body-s text-text-danger">Ble ikke godkjent. Prøv igjen.</p>}
          </div>
        );
      })}
      {open && (
        <>
          <p className="type-body-s text-text-tertiary">
            Stedet vises ikke på kartet. Ta et gruppebilde der, send det i lagets Telegram-gruppe og marker som levert. Første godkjente gir 2p.
          </p>
          {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
          <Button icon="check" block disabled={busy} onClick={deliver}>Marker som levert</Button>
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
