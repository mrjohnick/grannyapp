// Nye versjoner av appen. Service workeren lagrer appen lokalt, så uten dette
// fortsetter telefonen å vise den gamle versjonen etter en ny deploy.
// registerType «autoUpdate»: når en ny versjon er hentet, lastes siden på nytt.
import { registerSW } from "virtual:pwa-register";

// Ikke last på nytt mens noen holder på med kamera eller opplasting.
const busy = () => document.querySelector("video, input[type=file]") !== null;

export function startUpdates() {
  if (!("serviceWorker" in navigator)) return;
  registerSW({
    immediate: true,
    onRegisteredSW(_url, reg) {
      if (!reg) return;
      // Sjekk når appen kommer i forgrunnen igjen, ikke midt i bruk.
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible" && !busy()) reg.update().catch(() => {});
      });
    },
  });
}
