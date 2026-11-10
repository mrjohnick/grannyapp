import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import "./styles/index.css";
import { GameProvider } from "./lib/game";
import { Join } from "./routes/Join";
import { TelegramLink } from "./routes/TelegramLink";
import { GrannyHome } from "./routes/GrannyHome";
import { TeamHome } from "./routes/TeamHome";
import { AdminLive } from "./routes/AdminLive";

// Profilfontene (lisensierte) lastes bare når de finnes. Ellers brukes reservefontene.
const brandFonts = import.meta.env.VITE_BRAND_FONTS_URL as string | undefined;
if (brandFonts) {
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = brandFonts;
  document.head.appendChild(link);
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Join />} />
        <Route path="/granny/telegram" element={<GameProvider role="granny"><TelegramLink /></GameProvider>} />
        <Route path="/granny" element={<GameProvider role="granny"><GrannyHome /></GameProvider>} />
        <Route path="/lag" element={<GameProvider role="team"><TeamHome /></GameProvider>} />
        <Route path="/leder" element={<GameProvider role="admin"><AdminLive /></GameProvider>} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  </StrictMode>,
);
