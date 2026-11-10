import * as maplibregl from "maplibre-gl";
import type { StyleSpecification } from "maplibre-gl";
// MapLibre 6 laster workeren som egen modul. La Vite bunte den med avhengighetene.
import workerUrl from "maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url";

maplibregl.setWorkerUrl(workerUrl);
import { Protocol } from "pmtiles";
import { layers, namedFlavor, type Flavor } from "@protomaps/basemaps";

let protocolAdded = false;

function cssVar(name: string, fallback: string) {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v || fallback;
}

/**
 * Kartstil. Med VITE_PMTILES_URL brukes et eget Grimstad-utsnitt i
 * profilfargene. Uten det (lokal utvikling) brukes OpenStreetMap-fliser,
 * som ikke skal brukes i spillet (OSMs bruksvilkår tillater ikke tung bruk).
 */
export function mapStyle(): StyleSpecification {
  const pmtiles = import.meta.env.VITE_PMTILES_URL as string | undefined;

  if (!pmtiles) {
    return {
      version: 8,
      sources: {
        osm: {
          type: "raster",
          tiles: ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
          tileSize: 256,
          maxzoom: 19,
          attribution: "© OpenStreetMap",
        },
      },
      layers: [{ id: "osm", type: "raster", source: "osm", paint: { "raster-saturation": -0.6, "raster-opacity": 0.85 } }],
    };
  }

  if (!protocolAdded) {
    maplibregl.addProtocol("pmtiles", new Protocol().tile);
    protocolAdded = true;
  }

  const flavor: Flavor = {
    ...namedFlavor("light"),
    background: cssVar("--color-map-land", "#FBF3E6"),
    earth: cssVar("--color-map-land", "#FBF3E6"),
    water: cssVar("--color-map-water", "#B9D8FA"),
    park_a: cssVar("--color-map-park", "#D9F5EA"),
    park_b: cssVar("--color-map-park", "#D9F5EA"),
    wood_a: cssVar("--color-map-park", "#D9F5EA"),
    wood_b: cssVar("--color-map-park", "#D9F5EA"),
    buildings: cssVar("--color-map-block", "#F3E7D3"),
    minor_a: cssVar("--color-map-road", "#FFFFFF"),
    minor_b: cssVar("--color-map-road", "#FFFFFF"),
  };

  return {
    version: 8,
    glyphs: "https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf",
    sprite: "https://protomaps.github.io/basemaps-assets/sprites/v4/light",
    sources: {
      protomaps: { type: "vector", url: `pmtiles://${pmtiles}`, attribution: "© OpenStreetMap" },
    },
    layers: layers("protomaps", flavor, { lang: "nb" }),
  };
}
