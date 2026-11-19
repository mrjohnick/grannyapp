// Spilleder: felles ramme med meny. Hver del av spilleders arbeid har sin egen
// side under /leder, så sidemenyen ikke blir en lang liste med alt.
import { createContext, useCallback, useContext, useState } from "react";
import { NavLink, Outlet } from "react-router-dom";
import { supabase } from "../../lib/supabase";
import { useGame } from "../../lib/game";
import { NotificationBell } from "../../lib/events";
import { useInterval } from "../../lib/hooks";
import { formatClock } from "../../lib/gameClock";
import { Badge } from "../../components/ui";
import { Icon, type IconName } from "../../components/Icon";
import { LogoLockup } from "../../components/Logo";
import { PushChip } from "../../components/PushChip";
import { TelegramChip } from "../../components/TelegramAlerts";
import type { AdminLive as AdminLiveData } from "../../lib/types";

type Ctx = { live: AdminLiveData | null; reload: () => void };
const AdminContext = createContext<Ctx>({ live: null, reload: () => {} });

/** Posisjoner og status for alle (admin_live), hentet hvert 5. sekund for alle spilleder-sidene. */
export function useAdminLive() {
  return useContext(AdminContext);
}

const MENU: Array<{ to: string; end?: boolean; icon: IconName; label: string; badge?: "catches" | "quests" | "taxi" }> = [
  { to: "/leder", end: true, icon: "map", label: "Live", badge: "catches" },
  { to: "/leder/oppdrag", icon: "list", label: "Oppdrag", badge: "quests" },
  { to: "/leder/taxi", icon: "taxi", label: "Taxi", badge: "taxi" },
  { to: "/leder/poeng", icon: "trophy", label: "Poeng" },
  { to: "/leder/meldinger", icon: "megaphone", label: "Meldinger" },
  { to: "/leder/deltakere", icon: "users", label: "Deltakere" },
  { to: "/leder/oppsett", icon: "settings", label: "Oppsett" },
];

const STATUS = { setup: "Oppsett", running: "Pågår", paused: "Pause", ended: "Slutt" } as const;

export function AdminShell() {
  const { state, gameS } = useGame();
  const [live, setLive] = useState<AdminLiveData | null>(null);
  const [counts, setCounts] = useState({ catches: 0, quests: 0 });

  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc("admin_live");
    if (!error) setLive(data as AdminLiveData);
  }, []);
  useInterval(load, 5000);

  // Tall i menyen: fangster og leveringer som venter på spilleder.
  const loadCounts = useCallback(async () => {
    const [c, q] = await Promise.all([supabase.rpc("admin_catch_queue"), supabase.rpc("admin_quest_queue")]);
    setCounts({
      catches: Array.isArray(c.data) ? c.data.length : 0,
      quests: Array.isArray(q.data) ? q.data.length : 0,
    });
  }, []);
  useInterval(loadCounts, 6000);

  const badge = { catches: counts.catches, quests: counts.quests, taxi: live?.taxi_waiting.length ?? 0 };
  const statusBadge = (
    <Badge tone={state.status === "running" ? "success" : state.status === "paused" ? "warning" : "neutral"}>{STATUS[state.status]}</Badge>
  );

  return (
    <AdminContext.Provider value={{ live, reload: load }}>
      <div className="flex h-dvh flex-col bg-bg-app lg:flex-row">
        <header className="flex shrink-0 flex-col border-border-strong bg-bg-surface max-lg:border-b-2 lg:w-[232px] lg:border-r-2">
          {/* Mobil: én rad. Bred skjerm: logo og bjelle øverst, klokke og status under. */}
          <div className="px-4 pt-[max(12px,env(safe-area-inset-top))] pb-2 lg:pt-5">
            <div className="flex items-center gap-3">
              {/* Logoen skaleres med transform, så den trenger en ramme med riktig bredde. */}
              <span className="flex h-8 w-[124px] shrink-0 items-center"><LogoLockup scale={0.5} /></span>
              <span className="flex-1" />
              <span className="type-timer-m lg:hidden">{formatClock(gameS)}</span>
              <span className="max-sm:hidden lg:hidden">{statusBadge}</span>
              <NotificationBell />
            </div>
            <div className="mt-2 hidden items-center justify-between lg:flex">
              <span className="type-timer-m">{formatClock(gameS)}</span>
              {statusBadge}
            </div>
          </div>
          <nav aria-label="Spilleder" className="flex gap-1 overflow-x-auto px-3 pb-2 lg:flex-1 lg:flex-col lg:overflow-y-auto lg:pb-3">
            {MENU.map((m) => {
              const n = m.badge ? badge[m.badge] : 0;
              return (
                <NavLink
                  key={m.to}
                  to={m.to}
                  end={m.end}
                  className={({ isActive }) =>
                    `flex shrink-0 items-center gap-2 rounded-md px-3 py-2 type-label-m ${
                      isActive ? "bg-bg-brand-subtle text-text-brand" : "text-text-secondary hover:bg-bg-sunken"
                    }`
                  }
                >
                  <Icon name={m.icon} size={20} />
                  <span className="lg:flex-1">{m.label}</span>
                  {n > 0 && (
                    <span className="grid h-5 min-w-5 place-items-center rounded-full bg-bg-danger px-1 type-label-s leading-none text-text-on-danger">
                      {n}
                    </span>
                  )}
                </NavLink>
              );
            })}
          </nav>
          <div className="flex flex-wrap items-start gap-2 px-3 pb-2 empty:hidden lg:flex-col lg:p-3"><PushChip /><TelegramChip /></div>
        </header>
        <div className="min-h-0 min-w-0 flex-1"><Outlet /></div>
      </div>
    </AdminContext.Provider>
  );
}

/** Ramme for spilleder-sider uten kart: én rullbar kolonne. */
export function AdminPage({ title, intro, children }: { title: string; intro?: string; children: React.ReactNode }) {
  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto flex max-w-3xl flex-col gap-4 p-5 pb-10">
        <div>
          <h1 className="type-display-m">{title}</h1>
          {intro && <p className="type-body-s text-text-secondary">{intro}</p>}
        </div>
        {children}
      </div>
    </div>
  );
}
