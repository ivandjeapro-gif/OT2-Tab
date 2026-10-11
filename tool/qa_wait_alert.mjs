// Attend que l'alerte offroad soit franchement declenchee, puis capture.
//
// Le scenario GPS : mesures "sur le parcours" jusqu'a avance=300, puis le
// detour (ecart 15,30,60,80,100,110,115,120,125,130) qui depasse 40 m. La
// detection exige 15 s au-dessus du seuil d'entree, soit ~8 mesures a 2 s.
// On laisse donc tourner ~100 s pour etre en plein dans l'alerte, cadre rouge
// clignotant et bandeau affiche.
export default async function run(page, ui) {
  await page.setViewportSize({ width: 1280, height: 800 });
  // Fenetre d'alerte : le scenario passe sur le parcours (~15 s), entre dans
  // le detour, tient 15 s au-dessus du seuil, puis revient. Le pic rouge se
  // situe ~45-62 s apres le demarrage du scenario. On capture au milieu.
  await page.waitForTimeout(55000);
  return { url: page.url(), title: await page.title() };
}
