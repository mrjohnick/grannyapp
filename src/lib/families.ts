// Hvilket lag er familien til hver granny? En granny uten lag er en bonus-granny.
// Rømlingen er aldri bonus-granny, selv om hun ikke har noe lag.
import { useEffect, useMemo, useState } from "react";
import { supabase } from "./supabase";
import type { TeamColor } from "./types";

export type Family = { id: string; name: string; color: TeamColor };
export type GrannyTag = { kind: "family"; team: Family } | { kind: "bonus" };

type TeamRow = { id: string; name: string; color: TeamColor; assigned_granny_id: string | null };
type GrannyRow = { id: string; is_romling: boolean };

export const BONUS_LABEL = "★ Bonus";

export function useFamilies(refreshKey: unknown = null) {
  const [teams, setTeams] = useState<TeamRow[] | null>(null);
  const [grannies, setGrannies] = useState<GrannyRow[] | null>(null);

  useEffect(() => {
    let alive = true;
    // RLS gir bare rader fra eget spill. Rømlingen er skjult for alle unntatt spilleder.
    supabase.from("teams").select("id, name, color, assigned_granny_id").then(({ data }) => alive && data && setTeams(data as TeamRow[]));
    supabase.from("grannies").select("id, is_romling").then(({ data }) => alive && data && setGrannies(data as GrannyRow[]));
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
    return { ready, tagOf };
  }, [teams, grannies]);
}

/** Kort tekst til kart og lister: lagnavnet, eller «★ Bonus». */
export function tagText(tag: GrannyTag | null) {
  if (!tag) return null;
  return tag.kind === "family" ? tag.team.name : BONUS_LABEL;
}
