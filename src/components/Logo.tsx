export function LogoSymbol({ size = 64 }: { size?: number }) {
  return (
    <svg width={size} height={(size * 120) / 96} viewBox="0 0 96 120" fill="none" aria-hidden="true">
      <circle cx="48" cy="13" r="11" fill="#D7BEEB" />
      <path d="M48 118C48 118 88 85 88 56C88 33.9 70.1 16 48 16C25.9 16 8 33.9 8 56C8 85 48 118 48 118Z" fill="var(--color-bg-brand)" />
      <circle cx="48" cy="53" r="31" fill="#D7BEEB" />
      <circle cx="48" cy="58" r="25" fill="#FFFBF4" />
      <circle cx="31" cy="67" r="4.5" fill="#FF9DB8" />
      <circle cx="65" cy="67" r="4.5" fill="#FF9DB8" />
      <circle cx="38" cy="56" r="8.5" stroke="#26123A" strokeWidth="3.5" />
      <circle cx="58" cy="56" r="8.5" stroke="#26123A" strokeWidth="3.5" />
      <path d="M46.5 55C47.5 54 48.5 54 49.5 55" stroke="#26123A" strokeWidth="3.5" strokeLinecap="round" />
      <path d="M42 71C45 74 51 74 54 71" stroke="#26123A" strokeWidth="3.5" strokeLinecap="round" />
    </svg>
  );
}

export function LogoLockup({ scale = 1 }: { scale?: number }) {
  return (
    <div className="flex items-center gap-[14px]" style={{ transform: `scale(${scale})`, transformOrigin: "left center" }}>
      <LogoSymbol size={56} />
      <div className="flex flex-col text-text-primary">
        <div className="type-logo-undertittel">Where is</div>
        <div className="type-logo-ordmerke -mt-1">
          granny<span className="text-bg-accent">?</span>
        </div>
      </div>
    </div>
  );
}
