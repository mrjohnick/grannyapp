// Innloggingskoden holdes i adressen (?kode=…) hele tiden. Da virker
// «Åpne i nettleser» fra Telegram og andre apper: den nye nettleseren får en
// adresse med koden og logger rett inn. Koden ligger også i localStorage, så
// appen kan vise «Kopier lenke».
import { useEffect, useState } from "react";
import { supabase } from "./supabase";

const KEY = "granny.code"; // «granny.»-nøkler slettes ved «Logg ut»

const clean = (code: string | null | undefined) => code?.trim().toUpperCase() || null;

export function rememberCode(code: string) {
  try { localStorage.setItem(KEY, clean(code) ?? ""); } catch { /* privat modus */ }
}

export function storedCode(): string | null {
  try { return clean(localStorage.getItem(KEY)); } catch { return null; }
}

export function codeInUrl(search: string): string | null {
  return clean(new URLSearchParams(search).get("kode"));
}

export function loginLink(code: string) {
  return `${location.origin}/?kode=${encodeURIComponent(code)}`;
}

/** Koden telefonen er logget inn med. Hentes fra serveren hvis den ikke er lagret (eldre innlogginger). */
export function useMyCode(): string | null {
  const [code, setCode] = useState<string | null>(storedCode);
  useEffect(() => {
    if (code) return;
    let alive = true;
    supabase.rpc("my_join_code").then(({ data }) => {
      const c = clean(data as string | null);
      if (!alive || !c) return;
      rememberCode(c);
      setCode(c);
    });
    return () => { alive = false; };
  }, [code]);
  return code;
}
