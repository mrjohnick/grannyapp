// Lagets egne poeng (L6). Poengtavlen er hemmelig: bare spilleder ser alle lagene.
import type { TeamStatus } from "../lib/types";
import { Sheet } from "../components/ui";

export function ScoreSheet({ status, onClose }: { status: TeamStatus; onClose: () => void }) {
  return (
    <Sheet onClose={onClose}>
      <div className="flex items-baseline justify-between">
        <h2 className="type-display-m">Poeng</h2>
        <span className="type-timer-l">{status.points}p</span>
      </div>
      <p className="type-body-m text-text-secondary">
        Dette er poengene deres. Poengtavlen er hemmelig til spilleder kårer vinnerne etter spillet.
      </p>
      <p className="type-body-s text-text-tertiary">
        Dere får poeng for fangster og side quests når spilleder har godkjent dem.
      </p>
    </Sheet>
  );
}
