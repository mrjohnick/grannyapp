import { createContext, useContext, type ReactNode } from "react";
import { Navigate } from "react-router-dom";
import { useGameState } from "./hooks";
import type { GameState, Role } from "./types";

type Ctx = ReturnType<typeof useGameState> & { state: GameState };
const GameContext = createContext<Ctx | null>(null);

export function useGame() {
  const ctx = useContext(GameContext);
  if (!ctx) throw new Error("useGame må brukes inne i <GameProvider>");
  return ctx;
}

/** Laster spilltilstand og sender spilleren til riktig side for rollen. */
export function GameProvider({ role, children }: { role: Role; children: ReactNode }) {
  const game = useGameState();
  if (!game.loaded) return <div className="grid h-dvh place-items-center type-body-m text-text-secondary">Laster …</div>;
  if (!game.state) return <Navigate to="/" replace />;
  if (game.state.role !== role) return <Navigate to={homeFor(game.state.role)} replace />;
  return <GameContext.Provider value={{ ...game, state: game.state }}>{children}</GameContext.Provider>;
}

export function homeFor(role: Role) {
  return role === "admin" ? "/leder" : role === "team" ? "/lag" : "/granny";
}
