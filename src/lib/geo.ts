// Avstand og soner på klienten. Serveren sjekker alltid på nytt; dette er
// bare for å låse opp knapper og vise «X m unna».
import type { Zone } from "./types";

export type LatLng = { lat: number; lng: number };

/** Avstand i meter (haversine). */
export function distanceM(a: LatLng, b: LatLng): number {
  const R = 6_371_000;
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad;
  const dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

export function zoneCenter(z: Pick<Zone, "geojson">): LatLng | null {
  if (z.geojson.type !== "Point") return null;
  const [lng, lat] = z.geojson.coordinates;
  return { lat, lng };
}

/** Samme slingringsmonn som serveren: radius + nøyaktighet, maks 25 m ekstra. */
export function inZone(z: Pick<Zone, "geojson" | "radius_m">, at: (LatLng & { accuracy?: number }) | null): boolean {
  const c = zoneCenter(z);
  if (!c || !at || !z.radius_m) return false;
  return distanceM(c, at) <= z.radius_m + Math.min(at.accuracy ?? 0, 25);
}

export function distanceText(m: number): string {
  return m < 1000 ? `${Math.round(m / 10) * 10} m` : `${(m / 1000).toFixed(1).replace(".", ",")} km`;
}

/** «0:15» eller «1:05» → sekunder. Tom eller ugyldig gir null. */
export function parseGameTime(text: string): number | null {
  const m = /^\s*(\d+):(\d{1,2})\s*$/.exec(text);
  if (!m) return null;
  const mins = Number(m[2]);
  if (mins >= 60) return null;
  return Number(m[1]) * 3600 + mins * 60;
}
