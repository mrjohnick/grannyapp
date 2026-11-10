import { useEffect, useRef } from "react";
import * as maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import { mapStyle } from "./style";
import { iconSvg, type IconName } from "../components/Icon";
import type { MapMarker, MarkerKind, Zone } from "../lib/types";

// Grimstad sentrum
const CENTER: [number, number] = [8.5934, 58.3405];

const MARKER_STYLE: Record<MarkerKind, { bg: string; icon?: IconName; iconColor: string; halo?: string }> = {
  granny:      { bg: "var(--color-marker-granny)", icon: "granny", iconColor: "#fff" },
  own_granny:  { bg: "var(--color-marker-granny)", icon: "granny", iconColor: "#fff", halo: "var(--color-marker-kaffekroken)" },
  live:        { bg: "var(--color-marker-granny)", icon: "granny", iconColor: "#fff", halo: "var(--color-bg-accent)" },
  romling:     { bg: "var(--color-marker-romling)", icon: "help", iconColor: "var(--color-bg-app)" },
  anonym:      { bg: "var(--color-marker-anonym)", icon: "megaphone", iconColor: "#fff" },
  nabovakt:    { bg: "var(--color-marker-nabovakt)", icon: "eye", iconColor: "#fff" },
  kaffekroken: { bg: "var(--color-marker-kaffekroken)", icon: "coffee", iconColor: "var(--plomme-900)" },
  bingo:       { bg: "var(--color-marker-bingo)", icon: "bingo", iconColor: "#fff" },
  nattevakt:   { bg: "var(--color-marker-nattevakt)", icon: "moon", iconColor: "#fff" },
  meg:         { bg: "var(--color-marker-meg)", iconColor: "#fff", halo: "var(--color-marker-meg)" },
  team:        { bg: "var(--color-bg-surface)", iconColor: "#fff" },
  postkort:    { bg: "var(--color-bg-surface)", icon: "camera", iconColor: "var(--plomme-900)" },
};

const ZONE_COLOR: Partial<Record<Zone["kind"], string>> = {
  kaffekroken: "--color-marker-kaffekroken",
  bingo: "--color-marker-bingo",
  nattevakt: "--color-marker-nattevakt",
  nabovakt: "--color-marker-nabovakt",
  postkort: "--color-border-strong",
};

function markerElement(m: MapMarker) {
  const s = MARKER_STYLE[m.kind];
  const el = document.createElement("div");
  el.className = "flex flex-col items-center gap-1 pointer-events-none";
  const size = m.kind === "meg" ? 22 : m.kind === "team" ? 16 : 44;
  const dotBg = m.kind === "team" && m.color ? `var(--lag-${m.color})` : s.bg;
  el.innerHTML = `
    <div style="position:relative;width:60px;height:60px;display:flex;align-items:center;justify-content:center">
      ${s.halo ? `<div style="position:absolute;inset:0;border-radius:999px;background:${s.halo};opacity:.3"></div>` : ""}
      <div style="width:${size}px;height:${size}px;border-radius:999px;background:${dotBg};display:flex;align-items:center;justify-content:center;
                  border:3px solid ${s.halo && m.kind !== "meg" ? s.halo : "var(--color-bg-surface)"};box-shadow:var(--shadow-marker)">
        ${s.icon ? iconSvg(s.icon, 22, s.iconColor) : ""}
      </div>
    </div>
    ${m.label ? `<div style="margin-top:-6px;padding:2px 8px;border-radius:999px;background:var(--color-bg-inverse);color:var(--color-text-inverse);font:600 13px/16px var(--font-sans);white-space:nowrap">${escapeHtml(m.label)}</div>` : ""}`;
  return el;
}

function escapeHtml(s: string) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

/** Sirkel som polygon, for soner med radius i meter. */
function circle(lng: number, lat: number, radiusM: number, steps = 48): GeoJSON.Polygon {
  const coords: [number, number][] = [];
  const dLat = radiusM / 111_320;
  const dLng = radiusM / (111_320 * Math.cos((lat * Math.PI) / 180));
  for (let i = 0; i <= steps; i++) {
    const a = (i / steps) * 2 * Math.PI;
    coords.push([lng + dLng * Math.cos(a), lat + dLat * Math.sin(a)]);
  }
  return { type: "Polygon", coordinates: [coords] };
}

function zonesToGeoJSON(zones: Zone[]): GeoJSON.FeatureCollection {
  const css = getComputedStyle(document.documentElement);
  return {
    type: "FeatureCollection",
    features: zones.flatMap((z) => {
      if (z.kind === "area" && z.geojson.type === "Polygon") {
        return [{ type: "Feature", geometry: z.geojson, properties: { kind: "area", color: css.getPropertyValue("--color-border-strong").trim() } }];
      }
      if (z.geojson.type !== "Point" || !z.radius_m) return [];
      const [lng, lat] = z.geojson.coordinates;
      // Nabovakt: vis søkeradien (300 m), ikke innsjekkradien.
      const r = z.kind === "nabovakt" ? 300 : z.radius_m;
      return [{
        type: "Feature",
        geometry: circle(lng, lat, r),
        properties: { kind: z.kind, color: css.getPropertyValue(ZONE_COLOR[z.kind] ?? "--color-border-strong").trim() },
      }];
    }) as GeoJSON.Feature[],
  };
}

export function zoneMarkers(zones: Zone[]): MapMarker[] {
  return zones.flatMap((z) => {
    if (z.kind === "area" || z.geojson.type !== "Point") return [];
    const [lng, lat] = z.geojson.coordinates;
    return [{ key: `zone-${z.id}`, kind: z.kind as MarkerKind, lat, lng, label: z.label }];
  });
}

export function GameMap({
  zones = [],
  markers = [],
  follow,
}: {
  zones?: Zone[];
  markers?: MapMarker[];
  /** Sentrer kartet her første gang den er kjent. */
  follow?: { lat: number; lng: number } | null;
}) {
  const container = useRef<HTMLDivElement>(null);
  const map = useRef<maplibregl.Map | null>(null);
  const placed = useRef(new Map<string, maplibregl.Marker>());
  const centered = useRef(false);

  useEffect(() => {
    if (!container.current) return;
    const m = new maplibregl.Map({
      container: container.current,
      style: mapStyle(),
      center: CENTER,
      zoom: 14.5,
      attributionControl: { compact: true },
    });
    m.on("load", () => {
      m.addSource("zones", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
      m.addLayer({ id: "zones-fill", type: "fill", source: "zones", filter: ["!=", ["get", "kind"], "area"],
        paint: { "fill-color": ["get", "color"], "fill-opacity": 0.18 } });
      m.addLayer({ id: "zones-line", type: "line", source: "zones",
        paint: { "line-color": ["get", "color"], "line-width": ["case", ["==", ["get", "kind"], "area"], 3, 1.5],
                 "line-dasharray": [2, 2], "line-opacity": 0.7 } });
    });
    map.current = m;
    return () => {
      m.remove();
      map.current = null;
      placed.current.clear();
    };
  }, []);

  // Soner
  useEffect(() => {
    const m = map.current;
    if (!m) return;
    const apply = () => (m.getSource("zones") as maplibregl.GeoJSONSource | undefined)?.setData(zonesToGeoJSON(zones));
    if (m.isStyleLoaded() && m.getSource("zones")) apply();
    else m.once("load", apply);
  }, [zones]);

  // Markører: legg til, flytt, fjern
  useEffect(() => {
    const m = map.current;
    if (!m) return;
    const seen = new Set<string>();
    for (const mk of markers) {
      const id = `${mk.key}|${mk.kind}|${mk.label ?? ""}`;
      seen.add(id);
      const existing = placed.current.get(id);
      if (existing) existing.setLngLat([mk.lng, mk.lat]);
      else placed.current.set(id, new maplibregl.Marker({ element: markerElement(mk), anchor: "top", offset: [0, -30] }).setLngLat([mk.lng, mk.lat]).addTo(m));
    }
    for (const [id, marker] of placed.current) {
      if (!seen.has(id)) {
        marker.remove();
        placed.current.delete(id);
      }
    }
  }, [markers]);

  // Første gang: sentrer på spilleren, eller vis alle markørene.
  useEffect(() => {
    const m = map.current;
    if (!m || centered.current) return;
    if (follow) {
      centered.current = true;
      m.easeTo({ center: [follow.lng, follow.lat], zoom: 15.5 });
    } else if (markers.length > 1) {
      centered.current = true;
      const bounds = new maplibregl.LngLatBounds();
      for (const mk of markers) bounds.extend([mk.lng, mk.lat]);
      m.fitBounds(bounds, { padding: { top: 120, bottom: 160, left: 50, right: 50 }, maxZoom: 16, duration: 0 });
    }
  }, [follow, markers]);

  // Inline-stil: maplibre-gl.css setter position: relative på .maplibregl-map,
  // og den vinner over Tailwind-klasser (som ligger i et cascade layer).
  return <div ref={container} style={{ position: "absolute", inset: 0 }} />;
}
