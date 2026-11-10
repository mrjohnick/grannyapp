// F2b · Koble Telegram (granny)
import { useCallback, useState } from "react";
import { useNavigate } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { useGame } from "../lib/game";
import { useInterval } from "../lib/hooks";
import { Badge, Button } from "../components/ui";
import { Icon } from "../components/Icon";

type TelegramStatus = { link_token: string; linked: boolean; last_position_age_s: number | null };

const BOT = (import.meta.env.VITE_TELEGRAM_BOT_USERNAME as string | undefined) ?? "GrannyBot";

export function TelegramLink() {
  const { state } = useGame();
  const navigate = useNavigate();
  const [status, setStatus] = useState<TelegramStatus | null>(null);

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("my_telegram");
    if (data) setStatus(data as TelegramStatus);
  }, []);
  useInterval(load, 4000);

  const receiving = status?.last_position_age_s != null && status.last_position_age_s < 120;
  const url = status ? `https://t.me/${BOT}?start=${status.link_token}` : undefined;

  return (
    <div className="flex min-h-dvh flex-col gap-4 px-4 pt-10 pb-6">
      <div><Badge tone="brand">Granny · {state.granny?.name}</Badge></div>
      <h1 className="type-display-l">Del posisjonen din i Telegram</h1>
      <p className="type-body-l text-text-secondary">Da blir du med på pingene selv om skjermen er låst. Lagene ser deg bare ved ping.</p>

      <div className={`flex items-center gap-3 rounded-lg border-2 border-border-strong p-3 ${receiving ? "bg-bg-success-subtle" : "bg-bg-warning-subtle"}`}>
        <span className={`grid size-10 place-items-center rounded-full ${receiving ? "bg-bg-success" : "bg-bg-warning"}`}>
          <Icon name={receiving ? "check" : "clock"} size={20} />
        </span>
        <div>
          <div className="type-label-m">
            {receiving ? "Live-posisjon mottatt" : status?.linked ? "Koblet – venter på posisjon" : "Venter på posisjon"}
          </div>
          <div className="type-body-s text-text-secondary">
            {receiving ? `Sist oppdatert for ${status!.last_position_age_s} sek siden.` : "Når boten har fått den, kan du gå videre."}
          </div>
        </div>
      </div>

      <ol className="flex flex-col gap-3 rounded-lg border border-border-default bg-bg-surface p-4">
        {[
          ["Åpne GrannyBot", "Knappen under kobler deg til riktig granny."],
          ["Trykk ⊕ → Posisjon", "Nederst i chatten med boten."],
          ["Del live-posisjon", "Velg «Til jeg slår det av»."],
        ].map(([h, b], i) => (
          <li key={h} className="flex gap-3">
            <span className="grid size-7 shrink-0 place-items-center rounded-full bg-bg-brand-subtle type-label-s text-text-brand">{i + 1}</span>
            <div>
              <div className="type-label-m">{h}</div>
              <div className="type-body-s text-text-secondary">{b}</div>
            </div>
          </li>
        ))}
      </ol>

      <div className="flex gap-3 rounded-md bg-bg-danger-subtle p-3 type-body-s">
        <Icon name="alert" size={20} className="text-icon-danger" />
        Del i chatten med boten, ikke i lag-gruppa. Ikke sveip bort Telegram – da stopper delingen.
      </div>

      <div className="flex-1" />
      <a href={url} target="_blank" rel="noreferrer" className="contents">
        <Button icon="send" block disabled={!url}>Åpne Telegram</Button>
      </a>
      <Button variant="secondary" block disabled={!receiving} onClick={() => navigate("/granny")}>Videre</Button>
    </div>
  );
}
