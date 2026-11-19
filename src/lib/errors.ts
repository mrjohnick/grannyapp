// Feilmeldinger fra serveren er skrevet for spillerne. Her kan vi utdype noen.
const MORE: Record<string, string> = {
  "Spillet er ikke i gang": "Spillet er ikke i gang. Vent til spilleder starter eller fortsetter.",
  "Jakten har ikke startet": "Jakten starter 0:15. Grannyene har fortsatt forsprang.",
  "Krever lisens": "Rømlingen kan bare fanges med lisens fra Nattevakten.",
  "Kravet er ikke åpent lenger": "Det kravet er ikke åpent lenger. Spilleder har kanskje avgjort det.",
  "Taxi er sperret": "Du kan ta taxi én gang hver halvtime.",
  "Fotoalbumet er sperret": "Du kan sende til Fotoalbumet én gang i timen.",
  "Punktet er brukt": "Dere kan bruke hvert punkt én gang i timen.",
  "Vent til neste forsøk": "Dere kan prøve igjen hvert 20. minutt.",
  "Vi vet ikke hvor hun er ennå": "Vi vet ikke hvor hun er ennå. Velg en annen. Sladringen din er ikke brukt.",
  "Gi poeng, en evne eller begge": "Gi oppdraget minst 1 poeng.",
};

// Koder vi selv bruker i RPC-ene (raise exception … using errcode).
const OWN_CODES = new Set(["P0001", "P0002", "42501", "22023"]);

export function friendly(error: { message: string; code?: string } | null | undefined): string | null {
  if (!error) return null;
  if (MORE[error.message]) return MORE[error.message];
  if (!error.code || OWN_CODES.has(error.code)) return error.message;
  return "Noe gikk galt. Sjekk nettet og prøv igjen.";
}
