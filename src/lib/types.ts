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
    kind: "granny" | "own_granny" | "live" | "romling" | "anonym";
    id: string | null;
    name: string | null;
    live_reason: "sladret" | "spilleder" | "utenfor" | "bingo" | null;
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

export type TeamCatch = {
  id: string;
  granny_id: string;
  granny_name: string;
  status: "pending" | "confirmed" | "rejected" | "overridden" | "void";
  registered_s: number;
  age_s: number;
  admin_deciding: boolean;
};

export type PendingClaim = {
  id: string;
  team_id: string;
  team_name: string;
  team_color: TeamColor;
  registered_s: number;
  age_s: number;
};

export type AdminCatch = {
  id: string;
  status: "pending" | "rejected";
  granny_id: string;
  granny_name: string;
  is_romling: boolean;
  team_id: string;
  team_name: string;
  team_color: TeamColor;
  registered_s: number;
  age_s: number;
  overdue: boolean;
  competing: number;
};

export type GrannyRow = { id: string; name: string; is_romling: boolean; caught_at_s: number | null };

export type GameEvent = {
  id: number;
  at_s: number;
  kind: string;
  title: string;
  body: string | null;
  audience: string;
  data: Record<string, unknown> | null;
  created_at: string;
};

export type GrannyStatus = {
  game_s: number;
  points: number;
  taxi_rides: number;
  next_taxi_s: number | null;
  honnor_max_rides: number;
  honnor_min_free_s: number;
  snitch_used: boolean;
  fotoalbum_next_s: number | null;
  fotoalbum_pending: boolean;
  bingo_done: boolean;
  bingo_points_next: number;
  license_given: boolean;
  teams: Array<{ id: string; name: string; color: TeamColor }>;
  targets: Array<{ id: string; name: string }>;
};

export type GrannyMap = { game_s: number; markers: TeamMap["markers"] };

export type TeamStatus = {
  game_s: number;
  points: number;
  has_license: boolean;
  romling_name: string | null;
  romling_next_try_s: number | null;
  romling_attempts: number;
  nabovakt: Array<{ zone_id: string; number: number; label: string; next_s: number | null }>;
  postcards: Array<{
    zone_id: string;
    number: number;
    mission: string | null;
    opens_at_s: number;
    closes_at_s: number;
    won_by: string | null;
    my_status: "pending" | "approved" | "rejected" | null;
  }>;
  album_photos: Array<{ id: string; storage_path: string; at_s: number }>;
  scoreboard: Array<{ id: string; name: string; color: TeamColor; points: number; catches: number }>;
};

export type AdminPhoto = {
  id: string;
  kind: "fotoalbum" | "bingo" | "postkort";
  status: "pending";
  storage_path: string;
  submitted_at: string;
  submitted_s: number;
  granny_id: string | null;
  granny_name: string | null;
  team_id: string | null;
  team_name: string | null;
  team_color: TeamColor | null;
  target_team_id: string | null;
  target_team_name: string | null;
  postkort_number: number | null;
  mission: string | null;
  distance_m: number | null;
  zone_radius_m: number | null;
  competing: number | null;
};

export type SetupData = {
  game: {
    id: string;
    name: string;
    status: GameState["status"];
    duration_s: number;
    head_start_s: number;
    romling_reveal_s: number;
    ping_schedule_s: number[];
    rules: Record<string, number>;
  };
  grannies: Array<{ id: string; name: string; is_romling: boolean; code: string | null; telegram_linked: boolean; phones: number }>;
  teams: Array<{ id: string; name: string; color: TeamColor; assigned_granny_id: string | null; code: string | null; phones: number }>;
  admin_codes: string[];
  zones: Array<Zone & { opens_at_s: number | null; closes_at_s: number | null; mission: string | null }>;
};

export type Summary = {
  game_name: string;
  status: GameState["status"];
  game_s: number;
  grannies: Array<{
    id: string; name: string; catch_order: number | null; caught_at_s: number | null; caught_by: string | null;
    placement: number; tasks: number; total: number; taxi_rides: number;
  }>;
  romling: null | { name: string; caught_at_s: number | null; caught_by: string | null; licensed: Array<{ team: string; at_s: number }> };
  teams: Array<{ id: string; name: string; color: TeamColor; points: number; catches: number }>;
  catches: Array<{ order: number | null; granny: string; is_romling: boolean; team: string; at_s: number }>;
  snitches: Array<{ snitch: string; target: string; at_s: number; bonus: boolean }>;
  album: Array<{ photographer: string; team: string; at_s: number }>;
};
