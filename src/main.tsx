import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import "./styles/index.css";
import { GameProvider } from "./lib/game";
import { startUpdates } from "./lib/pwa";
import { Join } from "./routes/Join";
import { TelegramLink } from "./routes/TelegramLink";
import { GrannyHome } from "./routes/GrannyHome";
import { TeamHome } from "./routes/TeamHome";
import { TaxiHome } from "./routes/TaxiHome";
import { AdminLive } from "./routes/AdminLive";
import { AdminSetup } from "./routes/AdminSetup";
import { AdminShell } from "./routes/admin/AdminShell";
import { AdminMessagesPage, AdminPeoplePage, AdminPointsPage, AdminQuestsPage, AdminTaxiPage } from "./routes/admin/pages";

// Profilfontene (lisensierte) lastes bare når de finnes. Ellers brukes reservefontene.
const brandFonts = import.meta.env.VITE_BRAND_FONTS_URL as string | undefined;
if (brandFonts) {
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = brandFonts;
  document.head.appendChild(link);
}

startUpdates();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Join />} />
        <Route path="/granny/telegram" element={<GameProvider role="granny"><TelegramLink /></GameProvider>} />
        <Route path="/granny" element={<GameProvider role="granny"><GrannyHome /></GameProvider>} />
        <Route path="/lag" element={<GameProvider role="team"><TeamHome /></GameProvider>} />
        <Route path="/taxi" element={<GameProvider role="taxi"><TaxiHome /></GameProvider>} />
        {/* Spilleder: én ramme med meny, og én side per oppgave. */}
        <Route path="/leder" element={<GameProvider role="admin"><AdminShell /></GameProvider>}>
          <Route index element={<AdminLive />} />
          <Route path="oppdrag" element={<AdminQuestsPage />} />
          <Route path="taxi" element={<AdminTaxiPage />} />
          <Route path="poeng" element={<AdminPointsPage />} />
          <Route path="meldinger" element={<AdminMessagesPage />} />
          <Route path="deltakere" element={<AdminPeoplePage />} />
          <Route path="oppsett" element={<AdminSetup />} />
        </Route>
        {/* Oppsummeringen er nå spilleders Poeng-side. */}
        <Route path="/oppsummering" element={<Navigate to="/leder/poeng" replace />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  </StrictMode>,
);
