// Formen på svarene fra RPC-ene i supabase/migrations. Holdes for hånd til
// `pnpm db:types` tas i bruk for tabellene.

export type Role = "granny" | "team" | "admin";
export type TeamColor = "rod" | "oransje" | "gul" | "lime" | "gronn" | "turkis" | "bla" | "marine" | "rosa" | "brun";

export type GameState = {
  server_time: string;
  game_id: string;
  game_name: string;
  status: "setup" | "running" | "paused" | "ended";
  game_s: number;
  duration_s: number;
  head_start_s: number;
  romling_reveal_s: number;
  ping_schedule_s: number[];
  last_ping_s: number | null;
  next_ping_s: number | null;
  role: Role;
  team: null | {
    id: string;
    name: string;
    color: TeamColor;
    assigned_granny_id: string | null;
    assigned_granny_name: string | null;
    has_license: boolean;
    blind_until_s: number | null;
  };
  granny: null | {
    id: string;
    name: string;
    is_romling: boolean;
    caught: boolean;
    caught_at_s: number | null;
  };
};

export type MarkerKind =
  | "granny" | "own_granny" | "live" | "romling" | "anonym"
  | "nabovakt" | "kaffekroken" | "bingo" | "nattevakt" | "postkort" | "meg" | "team";

export type MapMarker = {
  key: string;
  kind: MarkerKind;
  lat: number;
  lng: number;
  label?: string | null;
  color?: string;
};

export type TeamMap = {
  game_s: number;
  ping_s: number | null;
  blind_until_s: number | null;
  markers: Array<{
    kind: "granny" | "own_granny" | "live" | "romling";
    id: string | null;
    name: string | null;
    live_reason: "sladret" | "utenfor" | null;
    lat: number;
    lng: number;
    accuracy_m: number | null;
    at_s: number;
    age_s: number;
  }>;
};

export type Zone = {
  id: string;
  kind: "area" | "kaffekroken" | "bingo" | "nattevakt" | "nabovakt" | "postkort";
  number: number | null;
  label: string;
  radius_m: number | null;
  geojson: GeoJSON.Point | GeoJSON.Polygon;
};

export type TelegramStats = {
  window_min: number;
  grannies: Array<{
    id: string;
    name: string;
    linked: boolean;
    updates: number;
    median_gap_s: number | null;
    p90_gap_s: number | null;
    max_gap_s: number | null;
    median_accuracy_m: number | null;
    last_age_s: number | null;
    live: boolean | null;
  }>;
};

export type AdminLive = {
  game_s: number;
  grannies: Array<{
    id: string;
    name: string;
    is_romling: boolean;
    caught_at_s: number | null;
    telegram_linked: boolean;
    lat: number | null;
    lng: number | null;
    source: "telegram" | "app" | null;
    age_s: number | null;
    live_reason: string | null;
  }>;
  teams: Array<{
    id: string;
    name: string;
    color: TeamColor;
    phones: number;
    lat: number | null;
    lng: number | null;
    age_s: number | null;
  }>;
};
