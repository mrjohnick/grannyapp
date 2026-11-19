// Formen på svarene fra RPC-ene i supabase/migrations. Holdes for hånd til
// `pnpm db:types` tas i bruk for tabellene.

export type Role = "granny" | "team" | "admin" | "taxi";
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
  /** Ping-tider for bonus-grannyer. Tom: samme som ping_schedule_s. */
  bonus_ping_schedule_s: number[];
  last_ping_s: number | null;
  /** For en granny: hennes egen neste ping. For andre: neste av begge listene. */
  next_ping_s: number | null;
  /** Neste ping gjelder bare bonus-grannyene. */
  next_ping_bonus: boolean;
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
    is_bonus: boolean;
    caught: boolean;
    caught_at_s: number | null;
    avatar_path: string | null;
  };
  taxi: null | { id: string; name: string };
};

export type MarkerKind =
  | "granny" | "own_granny" | "live" | "romling" | "anonym"
  | "nabovakt" | "kaffekroken" | "bingo" | "nattevakt" | "postkort" | "meg" | "team" | "taxi";

export type MapMarker = {
  key: string;
  kind: MarkerKind;
  lat: number;
  lng: number;
  label?: string | null;
  color?: string;
  /** Profilbilde (signert lenke) som vises i markøren i stedet for ikonet. */
  avatarUrl?: string | null;
  /** Bonus-granny: gul ring og stjerne rundt markøren. */
  bonus?: boolean;
};

export type TeamMap = {
  game_s: number;
  ping_s: number | null;
  blind_until_s: number | null;
  markers: Array<{
    kind: "granny" | "own_granny" | "live" | "romling" | "anonym" | "taxi";
    id: string | null;
    name: string | null;
    live_reason: "sladret" | "spilleder" | "evne" | "utenfor" | "bingo" | null;
    busy?: boolean;
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
  taxis: Array<{
    id: string;
    name: string;
    phones: number;
    lat: number | null;
    lng: number | null;
    age_s: number | null;
    ride: null | { status: "accepted" | "picked_up"; granny_name: string };
  }>;
  taxi_waiting: string[];
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
  selfie_path: string | null;
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
  taxi_max_rides: number;
  taxi_request: null | {
    status: "waiting" | "accepted" | "picked_up";
    taxi_name: string | null;
    queue_position: number | null;
    /** Fanget: står bak alle som ikke er fanget. */
    last_in_queue: boolean;
    /** Spillsekundet tiden i taxien er ute (null: ingen grense). */
    ride_ends_s: number | null;
  };
  taxis: number;
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
  grannies: Array<{ id: string; name: string; is_romling: boolean; avatar_path: string | null; code: string | null; telegram_linked: boolean; phones: number }>;
  teams: Array<{ id: string; name: string; color: TeamColor; assigned_granny_id: string | null; code: string | null; phones: number }>;
  taxis: Array<{ id: string; name: string; code: string | null; phones: number }>;
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

export type TaxiQueue = {
  game_s: number;
  taxi: { id: string; name: string } | null;
  active: null | {
    id: string;
    status: "accepted" | "picked_up";
    granny_name: string;
    granny_avatar: string | null;
    caught: boolean;
    requested_s: number;
    accepted_s: number | null;
    picked_s: number | null;
    lat: number | null;
    lng: number | null;
    position_s: number | null;
    /** Spillsekundet tiden i taxien er ute (null: ingen grense). */
    ride_ends_s: number | null;
    /** Hvor gammel grannyens posisjon er, i spillsekunder. */
    position_age_s: number | null;
  };
  /** Turen gis videre hvis appen ikke sender posisjon så lenge. */
  timeout_s: number;
  waiting: Array<{ id: string; granny_name: string; requested_s: number; caught: boolean }>;
  busy: number;
};

export type Quest = {
  id: string;
  title: string;
  description: string | null;
  reward_points: number;
  reward_abilities: number;
  closed: boolean;
};

export type TeamQuests = {
  abilities_left: number;
  ability_live_s: number;
  quests: Array<Quest & { status: "pending" | "approved" | "rejected" | null; note: string | null }>;
};

export type AdminQuest = Quest & {
  team_id: string | null;
  team_name: string | null;
  pending: number;
  approved_teams: string[];
};

export type QuestSubmission = {
  id: string;
  quest_id: string;
  quest_title: string;
  quest_description: string | null;
  reward_points: number;
  reward_abilities: number;
  team_id: string;
  team_name: string;
  team_color: TeamColor;
  storage_path: string;
  media: "image" | "video";
  submitted_s: number;
  submitted_at: string;
};
