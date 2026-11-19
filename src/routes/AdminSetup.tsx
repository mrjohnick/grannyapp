// S2 · Oppsett: tider, grannies, lag og soner. Tider, grannies og lag kan
// bare endres før spillet starter; navn, regler og soner kan justeres underveis.
import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase } from "../lib/supabase";
import { useGame } from "../lib/game";
import { friendly } from "../lib/errors";
import { formatGameTime } from "../lib/gameClock";
import { parseGameTime } from "../lib/geo";
import { GameMap, zoneMarkers } from "../map/GameMap";
import { Badge, Button, TeamDot } from "../components/ui";
import { Icon } from "../components/Icon";
import type { SetupData, TeamColor, Zone } from "../lib/types";
import { imageFileToJpeg, StoredPhoto, uploadPhoto } from "../features/camera";

const COLORS: Array<[TeamColor, string]> = [
  ["rod", "Rød"], ["oransje", "Oransje"], ["gul", "Gul"], ["lime", "Lime"], ["gronn", "Grønn"],
  ["turkis", "Turkis"], ["bla", "Blå"], ["marine", "Marine"], ["rosa", "Rosa"], ["brun", "Brun"],
];
const ZONE_KINDS: Array<[Zone["kind"], string, number]> = [
  // Alle punkt-sonene er tatt ut av spillet. Bare spillområdet tegnes nå.
];
const RULES: Array<[string, string, "min" | "s" | "m"]> = [
  ["taxi_max_rides", "Taxiturer per granny", "m"],
  ["taxi_driver_timeout_s", "Taxi uten svar gis videre etter (min)", "min"],
  ["taxi_ride_max_s", "Maks tid i taxi (min, 0 = ingen grense)", "min"],
  ["catch_points_bonus", "Bonus-granny, poeng", "m"],
  ["ability_live_s", "Live-evne varer (sek)", "s"],
  ["retention_days", "Slett data etter (dager)", "m"],
];

const field = "h-10 rounded-sm border border-border-strong bg-bg-surface px-2 type-body-m disabled:bg-bg-disabled";

type DraftZone = { id: string | null; kind: Zone["kind"]; label: string; number: string; radius: string; opens: string; closes: string; mission: string; lat: number | null; lng: number | null };

export function AdminSetup() {
  const [data, setData] = useState<SetupData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("game");

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("admin_setup");
    if (error) setError(friendly(error));
    else setData(data as SetupData);
  }, []);
  useEffect(() => { load(); }, [load]);

  async function call(fn: string, args: Record<string, unknown>, ok: string) {
    setError(null);
    const { error } = await supabase.rpc(fn, args);
    if (error) { setError(friendly(error)); return false; }
    setSaved(ok);
    setTimeout(() => setSaved(null), 2500);
    await load();
    return true;
  }

  if (!data) return <div className="grid h-full place-items-center type-body-m text-text-secondary">{error ?? "Laster …"}</div>;
  const locked = data.game.status !== "setup";

  return (
    <div className="flex h-full flex-col bg-bg-app lg:flex-row">
      <aside className="flex flex-col gap-4 overflow-y-auto border-border-strong bg-bg-surface p-5 max-lg:max-h-[60%] lg:w-[480px] lg:border-r-2">
        <div className="flex items-center justify-between">
          <h1 className="type-display-m">Oppsett</h1>
          <Badge tone={locked ? "warning" : "brand"}>{locked ? "Spillet er i gang" : "Før start"}</Badge>
        </div>
        {/* Én del om gangen, så siden ikke blir en lang liste. */}
        <div role="tablist" aria-label="Oppsett" className="flex flex-wrap gap-1 rounded-lg bg-bg-sunken p-1">
          {TABS.map(([key, label]) => (
            <button key={key} type="button" role="tab" aria-selected={tab === key} onClick={() => setTab(key)}
              className={`rounded-md px-3 py-1.5 type-label-s ${tab === key ? "bg-bg-surface text-text-brand shadow-sm" : "text-text-secondary"}`}>
              {label}{key === "grannies" ? ` (${data.grannies.length})` : key === "teams" ? ` (${data.teams.length})` : key === "taxis" ? ` (${data.taxis.length})` : ""}
            </button>
          ))}
        </div>
        {locked && <p className="rounded-md bg-bg-warning-subtle p-3 type-body-s">Tider, grannies og lag er låst når spillet har startet. Navn, regler, poeng per plassering og spillområdet kan fortsatt endres.</p>}
        {error && <p className="sticky top-0 z-10 rounded-md bg-bg-danger-subtle p-3 type-body-s text-text-danger">{error}</p>}
        {saved && <p className="sticky top-0 z-10 rounded-md bg-bg-success-subtle p-3 type-body-s">{saved}</p>}

        {tab === "game" && <GameSettings data={data} locked={locked} save={(s) => call("admin_update_game", { p_settings: s }, "Spillet er lagret.")} />}
        {tab === "grannies" && <Grannies data={data} locked={locked} call={call} />}
        {tab === "teams" && <Teams data={data} locked={locked} call={call} />}
        {tab === "taxis" && <Taxis data={data} call={call} />}
        {tab === "links" && <Codes data={data} />}
      </aside>
      <ZoneEditor data={data} call={call} />
    </div>
  );
}

const TABS = [["game", "Spillet"], ["grannies", "Grannies"], ["teams", "Lag"], ["taxis", "Taxier"], ["links", "Lenker"]] as const;
type Tab = (typeof TABS)[number][0];

// ---------------------------------------------------------------------------
function GameSettings({ data, locked, save }: { data: SetupData; locked: boolean; save: (s: Record<string, unknown>) => void }) {
  const g = data.game;
  // Bonus-tidene kommer fra game_state (admin_setup har dem ikke).
  const { state } = useGame();
  const [name, setName] = useState(g.name);
  const [times, setTimes] = useState({
    duration: formatGameTime(g.duration_s),
    pings: g.ping_schedule_s.map(formatGameTime).join(", "),
    bonus: (state.bonus_ping_schedule_s ?? []).map(formatGameTime).join(", "),
  });
  // Poeng per plassering for grannyene, 1. plass først.
  const [places, setPlaces] = useState((state.granny_place_points ?? []).join(", "));
  const [rules, setRules] = useState<Record<string, string>>(() =>
    Object.fromEntries(RULES.map(([k, , unit]) => [k, String(unit === "min" ? (g.rules[k] ?? 0) / 60 : g.rules[k] ?? "")])));
  const [problem, setProblem] = useState<string | null>(null);

  function submit() {
    const duration = parseGameTime(times.duration);
    const pings = times.pings.split(",").map((t) => parseGameTime(t));
    // Tomt felt: bonus-grannyene følger de vanlige ping-tidene.
    const bonus = times.bonus.trim() ? times.bonus.split(",").map((t) => parseGameTime(t)) : [];
    if (duration == null || pings.some((p) => p == null) || bonus.some((p) => p == null)) {
      return setProblem("Skriv tider som t:mm, f.eks. 0:15 eller 2:30. Ping-tider skilles med komma.");
    }
    const placePoints = places.trim() ? places.split(",").map((x) => Number(x.trim())) : [];
    if (placePoints.some((n) => !Number.isInteger(n) || n < 0)) {
      return setProblem("Poeng per plassering må være hele tall skilt med komma, f.eks. 20, 15, 12.");
    }
    setProblem(null);
    const ruleValues = RULES.map(([k, , unit]) => [k, Math.round(Number(rules[k]) * (unit === "min" ? 60 : 1))] as const);
    if (ruleValues.some(([, v]) => !Number.isFinite(v) || v < 0)) return setProblem("Reglene må være tall som er 0 eller mer.");
    const ruleObj = Object.fromEntries(ruleValues);
    // Etter start kan bare navn og regler endres.
    if (locked) return save({ name, rules: ruleObj, granny_place_points: placePoints });
    save({ name, duration_s: duration, head_start_s: 0, ping_schedule_s: pings, bonus_ping_schedule_s: bonus, rules: ruleObj, granny_place_points: placePoints });
  }

  return (
    <section className="flex flex-col gap-2">
      <h2 className="type-heading-m">Spillet</h2>
      <label className="flex flex-col gap-1 type-label-s">Navn<input className={field} value={name} onChange={(e) => setName(e.target.value)} /></label>
      <label className="flex w-32 flex-col gap-1 type-label-s">Varighet
        <input className={field} disabled={locked} value={times.duration} onChange={(e) => setTimes({ ...times, duration: e.target.value })} />
      </label>
      <label className="flex flex-col gap-1 type-label-s">Ping-tider
        <textarea className={`${field} h-16 py-1`} disabled={locked} value={times.pings} onChange={(e) => setTimes({ ...times, pings: e.target.value })} />
      </label>
      <label className="flex flex-col gap-1 type-label-s">Ping-tider for bonus-grannyer
        <textarea className={`${field} h-16 py-1`} disabled={locked} value={times.bonus} placeholder="Tomt: samme som over"
          onChange={(e) => setTimes({ ...times, bonus: e.target.value })} />
      </label>
      <label className="flex flex-col gap-1 type-label-s">Poeng per plassering for grannyer (1. plass først)
        <input className={field} value={places} placeholder="F.eks. 20, 15, 12, 9, 7, 5, 4, 3, 2, 1" onChange={(e) => setPlaces(e.target.value)} />
        <span className="type-body-s font-normal text-text-tertiary">
          Den som fanges først, får siste plass. Alle som er fri når spillet slutter, deler 1. plass. Plasser uten tall gir 0p.
        </span>
      </label>
      <details open>
        <summary className="cursor-pointer type-label-s text-text-brand">Regler{locked ? " (kan endres underveis)" : ""}</summary>
        <div className="mt-2 grid grid-cols-2 gap-2">
          {RULES.map(([k, label]) => (
            <label key={k} className="flex flex-col gap-1 type-body-s">{label}
              <input className={field} inputMode="numeric" value={rules[k]} onChange={(e) => setRules({ ...rules, [k]: e.target.value })} />
            </label>
          ))}
        </div>
      </details>
      {problem && <p className="type-body-s text-text-danger">{problem}</p>}
      <Button size="M" onClick={submit}>Lagre spillet</Button>
    </section>
  );
}

// ---------------------------------------------------------------------------
type Call = (fn: string, args: Record<string, unknown>, ok: string) => Promise<boolean>;

function Grannies({ data, locked, call }: { data: SetupData; locked: boolean; call: Call }) {
  const [newName, setNewName] = useState("");
  return (
    <section className="flex flex-col gap-2">
      <h2 className="type-heading-m">Grannies <span className="type-body-s text-text-tertiary">({data.grannies.length})</span></h2>
      {data.grannies.map((g) => <GrannyRow key={g.id} g={g} gameId={data.game.id} family={data.teams.find((t) => t.assigned_granny_id === g.id)?.name ?? null} locked={locked} call={call} />)}
      {!locked && (
        <div className="flex gap-2">
          <input className={`${field} flex-1`} value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="Ny granny" />
          <Button size="M" variant="secondary" disabled={!newName.trim()}
            onClick={async () => { if (await call("admin_save_granny", { p_id: null, p_name: newName, p_is_romling: false }, "Grannyen er lagt til.")) setNewName(""); }}>
            Legg til
          </Button>
        </div>
      )}
      <p className="type-body-s text-text-tertiary">En granny som ikke er «egen granny» for noe lag, er bonus-granny. Hun har egne ping-tider og en gul ring på kartet.</p>
    </section>
  );
}

function GrannyRow({ g, gameId, family, locked, call }: { g: SetupData["grannies"][number]; gameId: string; family: string | null; locked: boolean; call: Call }) {
  const [name, setName] = useState(g.name);
  const [uploading, setUploading] = useState(false);
  async function setPhoto(file: File | undefined) {
    if (!file) return;
    setUploading(true);
    try {
      const path = await uploadPhoto(gameId, await imageFileToJpeg(file), "avatar-");
      await call("admin_set_avatar", { p_granny: g.id, p_path: path }, "Profilbildet er lagret.");
    } catch (e) {
      alert((e as Error).message);
    } finally {
      setUploading(false);
    }
  }
  const dirty = name !== g.name;
  return (
    <div className="flex flex-wrap items-center gap-2 rounded-md border border-border-default p-2">
      <label className="relative size-10 shrink-0 cursor-pointer overflow-hidden rounded-full border-2 border-border-brand bg-bg-brand-subtle" title="Bytt profilbilde">
        {g.avatar_path
          ? <StoredPhoto path={g.avatar_path} className="size-full object-cover" />
          : <span className="grid size-full place-items-center type-label-s text-text-brand">{uploading ? "…" : "Bilde"}</span>}
        <input type="file" accept="image/*" className="hidden" disabled={uploading} onChange={(e) => setPhoto(e.target.files?.[0])} />
      </label>
      <input className={`${field} min-w-0 flex-1`} value={name} onChange={(e) => setName(e.target.value)} />
      {dirty && <Button size="M" onClick={() => call("admin_save_granny", { p_id: g.id, p_name: name, p_is_romling: false }, "Lagret.")}>Lagre</Button>}
      {!locked && !dirty && (
        <button type="button" className="text-text-danger" aria-label={`Slett ${g.name}`}
          onClick={() => confirm(`Slette ${g.name}?`) && call("admin_delete", { p_kind: "granny", p_id: g.id }, "Slettet.")}>
          <Icon name="x" size={20} />
        </button>
      )}
      <div className="flex w-full flex-wrap gap-2 type-body-s text-text-secondary">
        {!g.is_romling && (family ? <Badge tone="neutral">Familie: {family}</Badge> : <Badge tone="warning">★ Bonus-granny</Badge>)}
        <span className="type-timer-s">{g.code}</span>
        <span>· {g.phones} tlf</span>
        <span className={g.telegram_linked ? "text-text-success" : "text-text-warning"}>· {g.telegram_linked ? "Telegram koblet" : "Telegram ikke koblet"}</span>
      </div>
    </div>
  );
}

function Teams({ data, locked, call }: { data: SetupData; locked: boolean; call: Call }) {
  const used = new Set(data.teams.map((t) => t.color));
  const free = COLORS.find(([c]) => !used.has(c))?.[0];
  const [newName, setNewName] = useState("");
  return (
    <section className="flex flex-col gap-2">
      <h2 className="type-heading-m">Lag <span className="type-body-s text-text-tertiary">({data.teams.length})</span></h2>
      {data.teams.map((t) => <TeamRow key={t.id} t={t} data={data} locked={locked} call={call} />)}
      {!locked && free && (
        <div className="flex gap-2">
          <input className={`${field} flex-1`} value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="Nytt lag" />
          <Button size="M" variant="secondary" disabled={!newName.trim()}
            onClick={async () => { if (await call("admin_save_team", { p_id: null, p_name: newName, p_color: free, p_assigned: null }, "Laget er lagt til.")) setNewName(""); }}>
            Legg til
          </Button>
        </div>
      )}
    </section>
  );
}

function TeamRow({ t, data, locked, call }: { t: SetupData["teams"][number]; data: SetupData; locked: boolean; call: Call }) {
  const [name, setName] = useState(t.name);
  const [color, setColor] = useState(t.color);
  const [assigned, setAssigned] = useState(t.assigned_granny_id ?? "");
  const dirty = name !== t.name || color !== t.color || assigned !== (t.assigned_granny_id ?? "");
  return (
    <div className="flex flex-wrap items-center gap-2 rounded-md border border-border-default p-2">
      <TeamDot color={color} />
      <input className={`${field} min-w-0 flex-1`} value={name} onChange={(e) => setName(e.target.value)} />
      <select className={field} value={color} onChange={(e) => setColor(e.target.value as TeamColor)}>
        {COLORS.map(([c, l]) => <option key={c} value={c}>{l}</option>)}
      </select>
      <select className={`${field} w-full`} value={assigned} onChange={(e) => setAssigned(e.target.value)}>
        <option value="">Ingen egen granny</option>
        {data.grannies.filter((g) => !g.is_romling).map((g) => <option key={g.id} value={g.id}>Egen granny: {g.name}</option>)}
      </select>
      <div className="flex w-full items-center gap-2 type-body-s text-text-secondary">
        <span className="type-timer-s">{t.code}</span><span>· {t.phones} tlf</span>
        <span className="flex-1" />
        {dirty && <Button size="M" onClick={() => call("admin_save_team", { p_id: t.id, p_name: name, p_color: color, p_assigned: assigned || null }, "Lagret.")}>Lagre</Button>}
        {!locked && !dirty && (
          <button type="button" className="text-text-danger" aria-label={`Slett ${t.name}`}
            onClick={() => confirm(`Slette ${t.name}?`) && call("admin_delete", { p_kind: "team", p_id: t.id }, "Slettet.")}>
            <Icon name="x" size={20} />
          </button>
        )}
      </div>
    </div>
  );
}

function Taxis({ data, call }: { data: SetupData; call: Call }) {
  const [newName, setNewName] = useState("");
  return (
    <section className="flex flex-col gap-2">
      <h2 className="type-heading-m">Taxier <span className="type-body-s text-text-tertiary">({data.taxis.length})</span></h2>
      <p className="type-body-s text-text-tertiary">Hver sjåfør får sin egen innlogging. Grannyene ser taxiene på kartet og bestiller i appen.</p>
      {data.taxis.map((x) => <TaxiRow key={x.id} x={x} call={call} />)}
      <div className="flex gap-2">
        <input className={`${field} flex-1`} value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="Ny taxi, f.eks. «Taxi 1 – Ola»" />
        <Button size="M" variant="secondary" disabled={!newName.trim()}
          onClick={async () => { if (await call("admin_save_taxi", { p_id: null, p_name: newName }, "Taxien er lagt til.")) setNewName(""); }}>
          Legg til
        </Button>
      </div>
    </section>
  );
}

function TaxiRow({ x, call }: { x: SetupData["taxis"][number]; call: Call }) {
  const [name, setName] = useState(x.name);
  return (
    <div className="flex flex-wrap items-center gap-2 rounded-md border border-border-default p-2">
      <input className={`${field} min-w-0 flex-1`} value={name} onChange={(e) => setName(e.target.value)} />
      {name !== x.name
        ? <Button size="M" onClick={() => call("admin_save_taxi", { p_id: x.id, p_name: name }, "Lagret.")}>Lagre</Button>
        : (
          <button type="button" className="text-text-danger" aria-label={`Slett ${x.name}`}
            onClick={() => confirm(`Slette ${x.name}?`) && call("admin_delete", { p_kind: "taxi", p_id: x.id }, "Slettet.")}>
            <Icon name="x" size={20} />
          </button>
        )}
      <div className="flex w-full gap-2 type-body-s text-text-secondary">
        <span className="type-timer-s">{x.code}</span><span>· {x.phones} tlf</span>
      </div>
    </div>
  );
}

function Codes({ data }: { data: SetupData }) {
  const link = (code: string | null) => (code ? `${location.origin}/?kode=${code}` : "");
  const rows = [
    ...data.admin_codes.map((c) => ["Spilleder", c] as const),
    ...data.teams.map((t) => [t.name, t.code] as const),
    ...data.taxis.map((x) => [x.name, x.code] as const),
    ...data.grannies.map((g) => [g.is_romling ? `${g.name} (Rømling)` : g.name, g.code] as const),
  ];
  return (
    <details open className="rounded-md border border-border-default p-3">
      <summary className="cursor-pointer type-heading-s">Innloggingslenker</summary>
      <p className="mt-2 type-body-s text-text-tertiary">Del lenken med riktig person. Alle på et lag bruker samme lenke.</p>
      <ul className="mt-2 flex flex-col gap-1">
        {rows.map(([who, code]) => (
          <li key={`${who}-${code}`} className="flex items-center gap-2 type-body-s">
            <span className="w-28 shrink-0 truncate type-label-s">{who}</span>
            <code className="flex-1 truncate">{link(code)}</code>
            <button type="button" className="type-label-s text-text-brand" onClick={() => navigator.clipboard?.writeText(link(code))}>Kopier</button>
          </li>
        ))}
      </ul>
    </details>
  );
}

// ---------------------------------------------------------------------------
// Soner: trykk i kartet for å plassere
// ---------------------------------------------------------------------------
function toDraft(z?: SetupData["zones"][number]): DraftZone {
  const p = z?.geojson.type === "Point" ? z.geojson.coordinates : null;
  return {
    id: z?.id ?? null, kind: z?.kind ?? "postkort", label: z?.label ?? "", number: z?.number != null ? String(z.number) : "",
    radius: z?.radius_m != null ? String(z.radius_m) : "30",
    opens: z?.opens_at_s != null ? formatGameTime(z.opens_at_s) : "", closes: z?.closes_at_s != null ? formatGameTime(z.closes_at_s) : "",
    mission: z?.mission ?? "", lat: p ? p[1] : null, lng: p ? p[0] : null,
  };
}

function ZoneEditor({ data, call }: { data: SetupData; call: Call }) {
  const [draft, setDraft] = useState<DraftZone | null>(null);
  const [area, setArea] = useState<Array<[number, number]> | null>(null);

  const zones = useMemo<Zone[]>(() => {
    const list: Zone[] = data.zones.filter((z) => !(area && z.kind === "area"));
    if (area && area.length >= 3) {
      list.push({ id: "draft-area", kind: "area", number: null, label: "Nytt område", radius_m: null,
        geojson: { type: "Polygon", coordinates: [[...area, area[0]]] } });
    }
    return list;
  }, [data.zones, area]);

  const markers = useMemo(() => {
    const list = zoneMarkers(zones.filter((z) => z.id !== draft?.id));
    if (draft?.lat != null && draft.lng != null) list.push({ key: "draft", kind: draft.kind as never, lat: draft.lat, lng: draft.lng, label: draft.label || "Ny sone" });
    for (const [i, [lng, lat]] of (area ?? []).entries()) list.push({ key: `v${i}`, kind: "meg", lat, lng, label: String(i + 1) });
    return list;
  }, [zones, draft, area]);

  function onMapClick(at: { lat: number; lng: number }) {
    if (area) setArea([...area, [at.lng, at.lat]]);
    else if (draft) setDraft({ ...draft, lat: at.lat, lng: at.lng });
  }

  async function saveDraft() {
    if (!draft || draft.lat == null || draft.lng == null) return;
    const ok = await call("admin_save_zone", {
      p_id: draft.id, p_kind: draft.kind, p_label: draft.label,
      p_geojson: { type: "Point", coordinates: [draft.lng, draft.lat] },
      p_radius_m: Number(draft.radius) || null, p_number: draft.number ? Number(draft.number) : null,
      p_opens_at_s: draft.kind === "postkort" ? parseGameTime(draft.opens) : null,
      p_closes_at_s: draft.kind === "postkort" ? parseGameTime(draft.closes) : null,
      p_mission: draft.kind === "postkort" ? draft.mission : null,
    }, "Sonen er lagret.");
    if (ok) setDraft(null);
  }

  async function saveArea() {
    if (!area || area.length < 3) return;
    const existing = data.zones.find((z) => z.kind === "area");
    const ok = await call("admin_save_zone", {
      p_id: existing?.id ?? null, p_kind: "area", p_label: "Spillområdet",
      p_geojson: { type: "Polygon", coordinates: [[...area, area[0]]] },
    }, "Spillområdet er lagret.");
    if (ok) setArea(null);
  }

  return (
    <main className="relative flex min-h-[70vh] flex-1 flex-col">
      <div className="relative flex-1">
        <GameMap zones={zones} markers={markers} locate onClick={onMapClick} />
        {(draft || area) && (
          <div className="absolute inset-x-3 top-3 rounded-md bg-bg-inverse px-3 py-2 type-label-s text-text-inverse">
            {area ? `Trykk i kartet for hvert hjørne (${area.length} så langt).` : "Trykk i kartet der sonen skal være."}
          </div>
        )}
      </div>
      <div className="flex max-h-[45vh] flex-col gap-2 overflow-y-auto border-t-2 border-border-strong bg-bg-surface p-4">
        {draft ? (
          <div className="flex flex-col gap-2">
            <div className="flex flex-wrap gap-2">
              <select className={field} value={draft.kind} onChange={(e) => setDraft({ ...draft, kind: e.target.value as Zone["kind"], radius: String(ZONE_KINDS.find(([k]) => k === e.target.value)?.[2] ?? 30) })}>
                {ZONE_KINDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
              </select>
              <input className={`${field} flex-1`} placeholder="Navn (vises for spillerne)" value={draft.label} onChange={(e) => setDraft({ ...draft, label: e.target.value })} />
              {(draft.kind === "nabovakt" || draft.kind === "postkort") && (
                <input className={`${field} w-16`} placeholder="Nr." inputMode="numeric" value={draft.number} onChange={(e) => setDraft({ ...draft, number: e.target.value })} />
              )}
              <label className="flex items-center gap-1 type-body-s">Radius <input className={`${field} w-16`} inputMode="numeric" value={draft.radius} onChange={(e) => setDraft({ ...draft, radius: e.target.value })} /> m</label>
            </div>
            {draft.kind === "postkort" && (
              <div className="flex flex-wrap gap-2">
                <input className={`${field} w-20`} placeholder="Åpner" value={draft.opens} onChange={(e) => setDraft({ ...draft, opens: e.target.value })} />
                <input className={`${field} w-20`} placeholder="Stenger" value={draft.closes} onChange={(e) => setDraft({ ...draft, closes: e.target.value })} />
                <input className={`${field} flex-1`} placeholder="Oppdraget" value={draft.mission} onChange={(e) => setDraft({ ...draft, mission: e.target.value })} />
              </div>
            )}
            <div className="flex gap-2">
              <Button size="M" disabled={draft.lat == null} onClick={saveDraft}>{draft.lat == null ? "Trykk i kartet først" : "Lagre sone"}</Button>
              <Button size="M" variant="secondary" onClick={() => setDraft(null)}>Avbryt</Button>
              {draft.id && (
                <Button size="M" variant="danger" onClick={async () => { if (confirm("Slette sonen?") && await call("admin_delete", { p_kind: "zone", p_id: draft.id }, "Sonen er slettet.")) setDraft(null); }}>Slett</Button>
              )}
            </div>
          </div>
        ) : area ? (
          <div className="flex gap-2">
            <Button size="M" disabled={area.length < 3} onClick={saveArea}>Lagre område ({area.length} hjørner)</Button>
            <Button size="M" variant="secondary" onClick={() => setArea(area.slice(0, -1))} disabled={area.length === 0}>Angre</Button>
            <Button size="M" variant="secondary" onClick={() => setArea(null)}>Avbryt</Button>
          </div>
        ) : (
          <>
            <div className="flex flex-wrap gap-2">
              <Button size="M" variant="secondary" icon="map" onClick={() => setArea([])}>
                {data.zones.some((z) => z.kind === "area") ? "Tegn spillområdet på nytt" : "Tegn spillområdet"}
              </Button>
            </div>
            <ul className="flex flex-col gap-1">
              {data.zones.filter((z) => z.kind !== "area").map((z) => (
                <li key={z.id}>
                  <button type="button" onClick={() => setDraft(toDraft(z))} className="flex w-full items-center gap-2 rounded-sm px-2 py-1 text-left hover:bg-bg-sunken">
                    <Badge tone="neutral">{ZONE_KINDS.find(([k]) => k === z.kind)?.[1] ?? z.kind}</Badge>
                    <span className="flex-1 type-label-s">{z.label}{z.number != null ? ` (${z.number})` : ""}</span>
                    <span className="type-body-s text-text-tertiary">
                      {z.radius_m} m{z.kind === "postkort" && z.opens_at_s != null && z.closes_at_s != null ? ` · ${formatGameTime(z.opens_at_s)}–${formatGameTime(z.closes_at_s)}` : ""}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
            <p className="type-body-s text-text-tertiary">Postkort og Bingo er hemmelige. Legg dem bare inn her, aldri i repoet.</p>
          </>
        )}
      </div>
    </main>
  );
}
