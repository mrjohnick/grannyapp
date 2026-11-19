// Hvilket lag er familien til hver granny, og hvordan ser hun ut?
// En granny uten lag er en bonus-granny. Rømlingen er aldri bonus-granny.
import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import type { TeamColor } from "./types";

export type Family = { id: string; name: string; color: TeamColor };
export type GrannyTag = { kind: "family"; team: Family } | { kind: "bonus" };

type TeamRow = { id: string; name: string; color: TeamColor; assigned_granny_id: string | null };
type GrannyRow = { id: string; is_romling: boolean; avatar_path: string | null };

export const BONUS_LABEL = "★ Bonus";

export function useFamilies(refreshKey: unknown = null) {
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
      if (withPhoto.length === 0) return;
      const { data: signed } = await supabase.storage.from("photos").createSignedUrls(withPhoto.map((g) => g.avatar_path!), 3600);
      if (!alive || !signed) return;
      const byPath = new Map(signed.filter((x) => x.signedUrl).map((x) => [x.path, x.signedUrl]));
      setAvatars(Object.fromEntries(withPhoto.flatMap((g) => (byPath.get(g.avatar_path!) ? [[g.id, byPath.get(g.avatar_path!)!]] : []))));
    });
    return () => { alive = false; };
  }, [refreshKey]);

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
