// Hvilket lag er familien til hver granny, og hvordan ser hun ut?
// En granny uten lag er en bonus-granny. Rømlingen er aldri bonus-granny.
import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import { useGame } from "./game";
import type { TeamColor } from "./types";

export type Family = { id: string; name: string; color: TeamColor };
export type GrannyTag = { kind: "family"; team: Family } | { kind: "bonus" };

type TeamRow = { id: string; name: string; color: TeamColor; assigned_granny_id: string | null };
type GrannyRow = { id: string; is_romling: boolean; avatar_path: string | null };

export const BONUS_LABEL = "★ Bonus";

// Signerte lenker til profilbilder, husket per fil. Da lastes ikke bildene på
// nytt hver gang listen hentes, og lenkene fornyes før de går ut.
const SIGN_FOR_S = 12 * 3600;
const RENEW_AFTER_MS = 6 * 3600 * 1000;
const signedCache = new Map<string, { url: string; at: number }>();

async function signedUrls(paths: string[]): Promise<Map<string, string>> {
  const now = Date.now();
  const missing = paths.filter((p) => { const c = signedCache.get(p); return !c || now - c.at > RENEW_AFTER_MS; });
  if (missing.length > 0) {
    const { data } = await supabase.storage.from("photos").createSignedUrls(missing, SIGN_FOR_S);
    for (const x of data ?? []) if (x.signedUrl && x.path) signedCache.set(x.path, { url: x.signedUrl, at: now });
  }
  return new Map(paths.flatMap((p) => (signedCache.has(p) ? [[p, signedCache.get(p)!.url] as [string, string]] : [])));
}

/**
 * Henter lag og grannyer på nytt når spillets data_version øker (nytt navn,
 * nytt profilbilde, nytt lag …), så ingen trenger å laste siden på nytt.
 */
export function useFamilies(refreshKey: unknown = null) {
  const { state } = useGame();
  const dataVersion = state.data_version;
  const [teams, setTeams] = useState<TeamRow[] | null>(null);
  const [grannies, setGrannies] = useState<GrannyRow[] | null>(null);
  const [avatars, setAvatars] = useState<Record<string, string>>({});

  useEffect(() => {
    let alive = true;
    // RLS gir bare rader fra eget spill. Rømlingen er skjult for alle unntatt spilleder.
    supabase.from("teams").select("id, name, color, assigned_granny_id").then(({ data }) => alive && data && setTeams(data as TeamRow[]));
    supabase.from("grannies").select("id, is_romling, avatar_path").then(async ({ data }) => {
      if (!alive || !data) return;
      const rows = data as GrannyRow[];
      setGrannies(rows);
      const withPhoto = rows.filter((g) => g.avatar_path);
      const byPath = withPhoto.length > 0 ? await signedUrls(withPhoto.map((g) => g.avatar_path!)) : new Map<string, string>();
      if (!alive) return;
      setAvatars(Object.fromEntries(withPhoto.flatMap((g) => (byPath.get(g.avatar_path!) ? [[g.id, byPath.get(g.avatar_path!)!]] : []))));
    });
    return () => { alive = false; };
  }, [refreshKey, dataVersion]);

  return useMemo(() => {
    const family = new Map<string, Family>();
    for (const t of teams ?? []) if (t.assigned_granny_id) family.set(t.assigned_granny_id, { id: t.id, name: t.name, color: t.color });
    const known = new Map((grannies ?? []).map((g) => [g.id, g]));
    const ready = teams !== null && grannies !== null;

    /** null til dataene er hentet, og for Rømlingen. */
    function tagOf(grannyId: string | null | undefined): GrannyTag | null {
      if (!ready || !grannyId) return null;
      const f = family.get(grannyId);
      if (f) return { kind: "family", team: f };
      const g = known.get(grannyId);
      return g && !g.is_romling ? { kind: "bonus" } : null;
    }
    /** Signert lenke til profilbildet, eller null. */
    function avatarOf(grannyId: string | null | undefined): string | null {
      return grannyId ? avatars[grannyId] ?? null : null;
    }
    return { ready, tagOf, avatarOf };
  }, [teams, grannies, avatars]);
}

/** Kort tekst til kart og lister: lagnavnet, eller «★ Bonus». */
export function tagText(tag: GrannyTag | null) {
  if (!tag) return null;
  return tag.kind === "family" ? tag.team.name : BONUS_LABEL;
}
