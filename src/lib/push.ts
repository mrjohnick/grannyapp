// Web Push: abonner og lagre abonnementet hos serveren.
// iPhone: virker bare når appen er lagt til på Hjem-skjermen (iOS 16.4+).
import { supabase } from "./supabase";

const VAPID_PUBLIC_KEY = import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined;

export type PushState = "on" | "off" | "denied" | "unsupported" | "install" | "nokey";

export function isIos() {
  return /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
}

function isStandalone() {
  return window.matchMedia("(display-mode: standalone)").matches || (navigator as { standalone?: boolean }).standalone === true;
}

function keyBytes(base64: string) {
  const padded = (base64 + "=".repeat((4 - (base64.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

export async function pushState(): Promise<PushState> {
  if (!VAPID_PUBLIC_KEY) return "nokey";
  if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) {
    return isIos() && !isStandalone() ? "install" : "unsupported";
  }
  if (Notification.permission === "denied") return "denied";
  if (Notification.permission !== "granted") return "off";
  const reg = await navigator.serviceWorker.getRegistration();
  const sub = await reg?.pushManager.getSubscription();
  return sub ? "on" : "off";
}

async function save(sub: PushSubscription) {
  const json = sub.toJSON();
  const { error } = await supabase.rpc("save_push_subscription", {
    p_endpoint: sub.endpoint,
    p_p256dh: json.keys?.p256dh ?? "",
    p_auth: json.keys?.auth ?? "",
  });
  if (error) throw new Error(error.message);
}

/** Spør om tillatelse (må kalles fra et trykk) og lagrer abonnementet. */
export async function enablePush(): Promise<PushState> {
  const state = await pushState();
  if (state === "nokey" || state === "unsupported" || state === "install" || state === "denied") return state;
  const permission = await Notification.requestPermission();
  if (permission !== "granted") return permission === "denied" ? "denied" : "off";
  const reg = await Promise.race([
    navigator.serviceWorker.ready,
    new Promise<never>((_, reject) => setTimeout(() => reject(new Error("Ingen service worker")), 8000)),
  ]);
  const sub = (await reg.pushManager.getSubscription()) ??
    (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(VAPID_PUBLIC_KEY!) }));
  await save(sub);
  return "on";
}

/** Når tillatelsen allerede er gitt: send abonnementet på nytt (f.eks. etter ny innlogging). */
export async function refreshPush() {
  if ((await pushState()) !== "on") return;
  const reg = await navigator.serviceWorker.getRegistration();
  const sub = await reg?.pushManager.getSubscription();
  if (sub) await save(sub).catch(() => {});
}
