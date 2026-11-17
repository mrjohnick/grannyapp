import { useEffect, useState } from "react";
import { enablePush, pushState, type PushState } from "../lib/push";
import { Icon } from "./Icon";

const TEXT: Partial<Record<PushState, string>> = {
  off: "Slå på varsler",
  denied: "Varsler er blokkert",
  install: "Legg appen på Hjem-skjermen for varsler",
  unsupported: "Varsler virker ikke i denne nettleseren",
};

/** Liten knapp som ber om varsler. Skjules når varsler er på (eller ikke satt opp). */
export function PushChip() {
  const [state, setState] = useState<PushState | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { pushState().then(setState); }, []);
  if (!state || state === "on" || state === "nokey") return null;

  async function enable() {
    setBusy(true);
    try {
      setState(await enablePush());
    } catch {
      setState("unsupported");
    } finally {
      setBusy(false);
    }
  }

  return (
    <button
      type="button"
      disabled={busy || state !== "off"}
      onClick={enable}
      className="flex items-center gap-1 rounded-full border border-border-strong bg-bg-warning px-3 py-1 type-label-s disabled:bg-bg-sunken"
    >
      <Icon name="bell" size={16} /> {TEXT[state]}
    </button>
  );
}
