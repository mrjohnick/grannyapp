// Rundt profilbilde, med forbokstaven når bildet mangler.
export function Avatar({ name, url, size = 40 }: { name: string; url?: string | null; size?: number }) {
  return url ? (
    <img src={url} alt="" style={{ width: size, height: size }} className="shrink-0 rounded-full border-2 border-border-brand object-cover" />
  ) : (
    <span style={{ width: size, height: size }}
      className="grid shrink-0 place-items-center rounded-full border-2 border-border-brand bg-bg-brand-subtle type-heading-l text-text-brand">
      {name[0]}
    </span>
  );
}
