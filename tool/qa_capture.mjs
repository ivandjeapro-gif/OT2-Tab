// Capture du mode DEMO OFFROAD de l'ecran DT.
//
// La page monte directement DtScreen avec la session en demo : le GPS simule
// sort de route, depasse 40 m pendant 15 s, l'alerte se declenche. On attend
// assez pour etre franchement dans l'alerte, puis on capture.
export default async function run(page, ui) {
  await page.setViewportSize({ width: 1280, height: 800 });

  // Alerte des l'ouverture : une attente courte suffit (premieres mesures
  // GPS + chargement des tuiles OpenStreetMap).
  await page.waitForTimeout(20000);

  return { url: page.url(), title: await page.title() };
}
