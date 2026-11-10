import type { ButtonHTMLAttributes, ReactNode } from "react";
import { Icon, type IconName } from "./Icon";
import { formatClock, formatCountdown } from "../lib/gameClock";

// ---------------------------------------------------------------------------
// Button – Figma: Button (Type × State × Size)
// ---------------------------------------------------------------------------
type ButtonType = "primary" | "secondary" | "danger" | "ghost";

const BUTTON_STYLES: Record<ButtonType, string> = {
  primary: "bg-bg-brand text-text-on-brand border-2 border-border-strong shadow-hard active:bg-bg-brand-pressed",
  secondary: "bg-bg-surface text-text-primary border-2 border-border-strong shadow-hard active:bg-bg-sunken",
  danger: "bg-bg-danger text-text-on-danger border-2 border-border-strong shadow-hard active:bg-bg-danger-pressed",
  ghost: "bg-transparent text-text-brand active:bg-bg-brand-subtle",
};

export function Button({
  variant = "primary",
  size = "L",
  icon,
  block,
  children,
  className,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonType;
  size?: "L" | "M";
  icon?: IconName;
  block?: boolean;
}) {
  const sizing = size === "L" ? "h-14 px-6 type-label-l" : "h-12 px-4 type-label-m";
  return (
    <button
      type="button"
      className={[
        "inline-flex items-center justify-center gap-2 rounded-full transition-[transform,box-shadow] select-none",
        "active:translate-y-[2px] active:shadow-none",
        "disabled:bg-bg-disabled disabled:text-text-disabled disabled:border-border-default disabled:shadow-none disabled:translate-y-0",
        BUTTON_STYLES[variant],
        sizing,
        block ? "w-full" : "",
        className ?? "",
      ].join(" ")}
      {...rest}
    >
      {icon && <Icon name={icon} size={size === "L" ? 24 : 20} />}
      {children}
    </button>
  );
}

// ---------------------------------------------------------------------------
// Badge – Figma: Badge (Tone)
// ---------------------------------------------------------------------------
export type Tone = "neutral" | "brand" | "success" | "warning" | "danger" | "info" | "inverse";
const TONES: Record<Tone, string> = {
  neutral: "bg-bg-sunken text-text-secondary",
  brand: "bg-bg-brand-subtle text-text-brand",
  success: "bg-bg-success-subtle text-text-success",
  warning: "bg-bg-warning-subtle text-text-warning",
  danger: "bg-bg-danger-subtle text-text-danger",
  info: "bg-bg-info-subtle text-text-info",
  inverse: "bg-bg-inverse text-text-inverse",
};

export function Badge({ tone = "neutral", children }: { tone?: Tone; children: ReactNode }) {
  return <span className={`inline-flex items-center rounded-full px-2 py-1 type-label-caps ${TONES[tone]}`}>{children}</span>;
}

// ---------------------------------------------------------------------------
// TopBar – Figma: TopBar (Tilstand)
// ---------------------------------------------------------------------------
export function TopBar({
  gameS,
  nextPingS,
  status,
  blindUntilS,
  caught,
}: {
  gameS: number;
  nextPingS: number | null;
  status: "setup" | "running" | "paused" | "ended";
  blindUntilS?: number | null;
  caught?: boolean;
}) {
  const toPing = nextPingS === null ? null : nextPingS - gameS;
  const blind = blindUntilS != null && blindUntilS > gameS;
  const soon = !blind && !caught && toPing !== null && toPing <= 30;

  let label = "Neste ping";
  let value = toPing === null ? "–" : formatCountdown(toPing);
  if (status === "setup") { label = "Status"; value = "Venter"; }
  if (status === "paused") { label = "Status"; value = "Pause"; }
  if (status === "ended") { label = "Status"; value = "Slutt"; }
  if (blind) { label = "Blind i"; value = formatCountdown(blindUntilS! - gameS); }
  if (caught) { label = "Status"; value = "Ute"; }

  const tone = blind || caught
    ? "bg-bg-inverse text-text-inverse"
    : soon
      ? "bg-bg-warning text-text-on-warning"
      : "bg-bg-surface text-text-primary";

  return (
    <header className={`flex items-center justify-between border-b-2 border-border-strong px-4 py-2 pt-[max(8px,env(safe-area-inset-top))] ${tone}`}>
      <div>
        <div className="type-label-caps opacity-80">Spilletid</div>
        <div className="type-timer-l">{formatClock(gameS)}</div>
      </div>
      <div className="text-right">
        <div className="type-label-caps opacity-80">{label}</div>
        <div className="type-timer-l">{value}</div>
      </div>
    </header>
  );
}

// ---------------------------------------------------------------------------
// Lagfarge
// ---------------------------------------------------------------------------
export function TeamDot({ color, size = 16 }: { color: string; size?: number }) {
  return (
    <span
      className="inline-block shrink-0 rounded-full border-2 border-bg-surface"
      style={{ width: size, height: size, background: `var(--lag-${color})` }}
    />
  );
}

export function Screen({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={`flex h-dvh flex-col overflow-hidden bg-bg-app ${className ?? ""}`}>{children}</div>;
}
