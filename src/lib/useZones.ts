import { useCallback, useState } from "react";
import { supabase } from "./supabase";
import { useInterval } from "./hooks";
import type { Zone } from "./types";

/** Sonene spilleren har lov til å se (RLS bestemmer). Hentes på nytt hvert minutt,
 *  så Nattevaktens post dukker opp for lagene kl. 0:45. */
export function useZones() {
  const [zones, setZones] = useState<Zone[]>([]);
  const load = useCallback(async () => {
    const { data, error } = await supabase.from("zones_geo").select("id, kind, number, label, radius_m, geojson");
    if (!error && data) setZones(data as Zone[]);
  }, []);
  useInterval(load, 60_000);
  return zones;
}
