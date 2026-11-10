/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { VitePWA } from "vite-plugin-pwa";

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: "autoUpdate",
      includeAssets: ["icon.svg", "apple-touch-icon.png"],
      manifest: {
        name: "Where is granny?",
        short_name: "Granny",
        lang: "nb",
        start_url: "/",
        display: "standalone",
        orientation: "portrait",
        theme_color: "#6A369B",
        background_color: "#FFFBF4",
        // PNG-ene er eksportert fra Figma-rammen «Eksport/App-ikon 1024» (helflate, uten hjørneradius).
        // Symbolet ligger innenfor maskable-sonen (sentrale 80 %), så samme fil brukes til begge formål.
        icons: [
          { src: "icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
          { src: "icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
          { src: "icon-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
        ],
      },
      workbox: {
        navigateFallback: "/index.html",
        globPatterns: ["**/*.{js,css,html,svg,woff2}"],
        maximumFileSizeToCacheInBytes: 4 * 1024 * 1024,
      },
    }),
  ],
  worker: { format: "es" },
  test: {
    include: ["src/**/*.test.ts"],
  },
});
