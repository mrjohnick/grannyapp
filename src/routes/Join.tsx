// F1 · Bli med
import { useEffect, useState, type FormEvent } from "react";
import { useNavigate } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { homeFor } from "../lib/game";
import type { GameState, Role } from "../lib/types";
import { Button } from "../components/ui";
import { LogoLockup } from "../components/Logo";

export function Join() {
  const navigate = useNavigate();
  const [code, setCode] = useState(() => new URLSearchParams(location.search).get("kode") ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Allerede med i et spill? Gå rett videre.
  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      if (!data.session) return;
      const { data: state } = await supabase.rpc("game_state");
      if (state) navigate(homeFor((state as GameState).role), { replace: true });
    });
  }, [navigate]);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!code.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const { data: s } = await supabase.auth.getSession();
      if (!s.session) {
        const { error } = await supabase.auth.signInAnonymously();
        if (error) throw new Error("Kunne ikke logge inn. Sjekk nettet og prøv igjen.");
      }
      const { data, error } = await supabase.rpc("join_game", { p_code: code });
      if (error) {
        throw new Error(error.message === "Ukjent kode" ? "Den koden finnes ikke. Sjekk lappen fra spilleder." : "Noe gikk galt. Prøv igjen.");
      }
      const role = (data as { role: Role }).role;
      navigate(role === "granny" ? "/granny/telegram" : homeFor(role), { replace: true });
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="flex min-h-dvh flex-col gap-5 bg-bg-brand-subtle px-6 pt-16 pb-8">
      <LogoLockup />
      <div className="flex-1" />
      <h1 className="type-display-l">Bli med i jakten</h1>
      <p className="type-body-l text-text-secondary">Skriv koden du fikk av spillederen. Den bestemmer rolle og lag.</p>
      <label className="flex flex-col gap-2">
        <span className="type-label-m">Spillkode</span>
        <input
          value={code}
          onChange={(e) => setCode(e.target.value.toUpperCase())}
          autoCapitalize="characters"
          autoComplete="off"
          spellCheck={false}
          placeholder="F.eks. BLÅ-4827"
          className={`h-14 rounded-md border-2 bg-bg-surface px-4 type-body-l outline-none focus:border-[3px] focus:border-border-focus ${
            error ? "border-border-danger bg-bg-danger-subtle" : "border-border-strong"
          }`}
        />
        <span className={`type-body-s ${error ? "text-text-danger" : "text-text-secondary"}`}>
          {error ?? "Står på lappen fra spilleder. Du kan også skanne QR-koden."}
        </span>
      </label>
      <Button type="submit" disabled={busy || !code.trim()} block>
        {busy ? "Logger inn …" : "Bli med"}
      </Button>
    </form>
  );
}
