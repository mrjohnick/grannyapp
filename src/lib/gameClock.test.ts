import { describe, expect, it } from "vitest";
import { currentGameSeconds, formatClock, formatCountdown, formatGameTime, lastPing, nextPing } from "./gameClock";

const SCHEDULE = [900, 1800, 2700, 3600, 4500, 5100, 5700, 6300, 6900, 7200, 7500, 7800, 8100, 8400, 8700, 9000];

describe("formatering", () => {
  it("viser spillklokka som t:mm:ss", () => {
    expect(formatClock(0)).toBe("0:00:00");
    expect(formatClock(4062)).toBe("1:07:42");
    expect(formatClock(9000)).toBe("2:30:00");
  });
  it("viser nedtelling uten timer når under en time", () => {
    expect(formatCountdown(438)).toBe("7:18");
    expect(formatCountdown(12.2)).toBe("0:13");
    expect(formatCountdown(3725)).toBe("1:02:05");
  });
  it("viser spilltid som i specen", () => {
    expect(formatGameTime(2700)).toBe("0:45");
    expect(formatGameTime(7500)).toBe("2:05");
  });
});

describe("ping", () => {
  it("har ingen ping før jakten starter 0:15", () => {
    expect(lastPing(SCHEDULE, 899)).toBeNull();
    expect(nextPing(SCHEDULE, 0)).toBe(900);
  });
  it("teller et ping som skjedd i det sekundet det skjer", () => {
    expect(lastPing(SCHEDULE, 900)).toBe(900);
    expect(nextPing(SCHEDULE, 900)).toBe(1800);
  });
  it("går over til hvert 10. og 5. minutt", () => {
    expect(nextPing(SCHEDULE, 4500)).toBe(5100);
    expect(nextPing(SCHEDULE, 7200)).toBe(7500);
  });
  it("har ingen neste ping etter slutt", () => {
    expect(nextPing(SCHEDULE, 9000)).toBeNull();
  });
});

describe("currentGameSeconds", () => {
  const snap = { status: "running" as const, game_s: 1000, duration_s: 9000, server_time: "2026-11-21T10:00:00Z" };
  it("teller videre lokalt mens spillet går", () => {
    expect(currentGameSeconds(snap, 0, 30_000)).toBe(1030);
  });
  it("står stille under pause", () => {
    expect(currentGameSeconds({ ...snap, status: "paused" }, 0, 30_000)).toBe(1000);
  });
  it("går aldri forbi slutt", () => {
    expect(currentGameSeconds(snap, 0, 99_000_000)).toBe(9000);
  });
});
