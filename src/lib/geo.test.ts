import { describe, expect, it } from "vitest";
import { distanceM, distanceText, inZone, parseGameTime } from "./geo";

const kaffekroken = { geojson: { type: "Point", coordinates: [8.5945, 58.341] } as GeoJSON.Point, radius_m: 40 };

describe("geo", () => {
  it("regner avstand i meter", () => {
    // 0,001 grader nord ≈ 111 m
    expect(distanceM({ lat: 58.341, lng: 8.5945 }, { lat: 58.342, lng: 8.5945 })).toBeCloseTo(111, 0);
  });
  it("står i sonen innenfor radius, med inntil 25 m slingringsmonn", () => {
    expect(inZone(kaffekroken, { lat: 58.341, lng: 8.5945 })).toBe(true);
    expect(inZone(kaffekroken, { lat: 58.3415, lng: 8.5945, accuracy: 5 })).toBe(false); // 56 m
    expect(inZone(kaffekroken, { lat: 58.3415, lng: 8.5945, accuracy: 100 })).toBe(true); // 40 + 25
    expect(inZone(kaffekroken, null)).toBe(false);
  });
  it("skriver avstand kort", () => {
    expect(distanceText(123)).toBe("120 m");
    expect(distanceText(1530)).toBe("1,5 km");
  });
  it("leser spilltid som t:mm", () => {
    expect(parseGameTime("0:15")).toBe(900);
    expect(parseGameTime("2:30")).toBe(9000);
    expect(parseGameTime("1:75")).toBeNull();
    expect(parseGameTime("abc")).toBeNull();
  });
});
