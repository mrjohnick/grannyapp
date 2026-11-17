// Kamera i appen. Specen krever at bildene tas her, ikke fra kamerarullen,
// så vi bruker getUserMedia i stedet for <input type="file">.
import { useEffect, useRef, useState } from "react";
import { supabase } from "../lib/supabase";
import { Button } from "../components/ui";
import { Icon } from "../components/Icon";

const MAX_SIDE = 1600;

export function CameraCapture({
  title,
  hint,
  onSend,
  onClose,
}: {
  title: string;
  hint?: string;
  /** Kalles med bildet. Kast en Error med en lesbar melding hvis det feiler. */
  onSend: (photo: Blob) => Promise<void>;
  onClose: () => void;
}) {
  const video = useRef<HTMLVideoElement>(null);
  const [facing, setFacing] = useState<"environment" | "user">("environment");
  const [photo, setPhoto] = useState<{ blob: Blob; url: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (photo) return;
    let stream: MediaStream | null = null;
    let cancelled = false;
    navigator.mediaDevices?.getUserMedia({ video: { facingMode: { ideal: facing }, width: { ideal: 1920 } }, audio: false })
      .then((s) => {
        if (cancelled) return s.getTracks().forEach((t) => t.stop());
        stream = s;
        if (video.current) {
          video.current.srcObject = s;
          video.current.play().catch(() => {});
        }
        setError(null);
      })
      .catch(() => setError("Fikk ikke tilgang til kameraet. Gi appen tilgang i nettleserinnstillingene."));
    if (!navigator.mediaDevices) setError("Denne nettleseren har ikke kamera-tilgang.");
    return () => {
      cancelled = true;
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, [facing, photo]);

  useEffect(() => () => { if (photo) URL.revokeObjectURL(photo.url); }, [photo]);

  function shoot() {
    const v = video.current;
    if (!v || !v.videoWidth) return;
    const scale = Math.min(1, MAX_SIDE / Math.max(v.videoWidth, v.videoHeight));
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(v.videoWidth * scale);
    canvas.height = Math.round(v.videoHeight * scale);
    canvas.getContext("2d")!.drawImage(v, 0, 0, canvas.width, canvas.height);
    canvas.toBlob((b) => b && setPhoto({ blob: b, url: URL.createObjectURL(b) }), "image/jpeg", 0.82);
  }

  async function send() {
    if (!photo) return;
    setBusy(true);
    setError(null);
    try {
      await onSend(photo.blob);
    } catch (e) {
      setError((e as Error).message);
      setBusy(false);
    }
  }

  return (
    <div className="fixed inset-0 z-40 flex flex-col bg-bg-inverse text-text-inverse">
      <div className="flex items-center justify-between px-4 pt-[max(12px,env(safe-area-inset-top))] pb-3">
        <button type="button" onClick={onClose} className="grid size-11 place-items-center rounded-full bg-bg-surface text-text-primary" aria-label="Lukk">
          <Icon name="x" />
        </button>
        <div className="text-center">
          <div className="type-label-l">{title}</div>
          {hint && <div className="type-body-s opacity-80">{hint}</div>}
        </div>
        <button
          type="button"
          onClick={() => setFacing((f) => (f === "environment" ? "user" : "environment"))}
          disabled={!!photo}
          className="grid size-11 place-items-center rounded-full bg-bg-surface text-text-primary disabled:opacity-40"
          aria-label="Bytt kamera"
        >
          <Icon name="camera" />
        </button>
      </div>
      <div className="relative flex-1 overflow-hidden">
        {photo
          ? <img src={photo.url} alt="Bildet du tok" className="absolute inset-0 size-full object-contain" />
          : <video ref={video} playsInline muted className="absolute inset-0 size-full object-cover" />}
      </div>
      <div className="flex flex-col gap-3 px-4 pt-4 pb-[max(24px,env(safe-area-inset-bottom))]">
        {error && <p className="rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
        {photo ? (
          <div className="flex gap-3">
            <Button variant="secondary" className="flex-1" disabled={busy} onClick={() => setPhoto(null)}>Ta nytt</Button>
            <Button icon="send" className="flex-1" disabled={busy} onClick={send}>{busy ? "Sender …" : "Send"}</Button>
          </div>
        ) : (
          <button
            type="button"
            onClick={shoot}
            aria-label="Ta bilde"
            className="mx-auto size-20 rounded-full border-4 border-bg-surface bg-bg-accent shadow-hard active:scale-95"
          />
        )}
      </div>
    </div>
  );
}

/** Last opp til Storage under <game_id>/ og returner stien. */
export async function uploadPhoto(gameId: string, blob: Blob): Promise<string> {
  const path = `${gameId}/${crypto.randomUUID()}.jpg`;
  const { error } = await supabase.storage.from("photos").upload(path, blob, { contentType: "image/jpeg", upsert: false });
  if (error) throw new Error("Bildet ble ikke lastet opp. Sjekk nettet og prøv igjen.");
  return path;
}

/** Hent et bilde som privat, tidsbegrenset lenke. */
export async function photoUrl(path: string): Promise<string | null> {
  const { data } = await supabase.storage.from("photos").createSignedUrl(path, 3600);
  return data?.signedUrl ?? null;
}

export function StoredPhoto({ path, className }: { path: string; className?: string }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    photoUrl(path).then((u) => alive && setUrl(u));
    return () => { alive = false; };
  }, [path]);
  return url
    ? <img src={url} alt="" className={className} />
    : <div className={`grid place-items-center bg-bg-sunken type-body-s text-text-tertiary ${className ?? ""}`}>Henter bilde …</div>;
}
