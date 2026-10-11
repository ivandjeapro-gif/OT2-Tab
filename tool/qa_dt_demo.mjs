// QA visuelle du mode DEMO OFFROAD de l'ecran DT.
//
// Flutter web dessine l'interface dans un <flt-glass-pane> / canvas : il n'y a
// aucun element HTML a cibler par selecteur. On pilote donc a la souris, par
// coordonnees, exactement comme un doigt sur la tablette.
export default async function run(page, ui) {
  // Fenetre au format tablette (paysage large) : c'est le format de reference.
  await page.setViewportSize({ width: 1280, height: 800 });

  // Le splash reste 3 s, puis l'ecran de connexion. On clique 5 fois sur le
  // logo (centre haut de l'ecran) pour activer le mode demo.
  const { width, height } = page.viewportSize();
  // Le logo est centre horizontalement, a environ 30 % de la hauteur.
  const logoX = width / 2;
  const logoY = height * 0.30;

  const clicks = [];
  for (let i = 0; i < 6; i++) {
    await page.mouse.click(logoX, logoY);
    clicks.push(i + 1);
    await page.waitForTimeout(150);
  }

  // Laisse le splash se terminer et le mode demo s'activer.
  await page.waitForTimeout(4000);

  // Le scenario GPS : ~7 mesures "sur le parcours" avant le detour, a 2 s par
  // mesure = ~14 s, puis le detour qui depasse 40 m pendant 15 s. On attend
  // donc assez pour entrer franchement dans l'alerte (~40 s au total).
  await page.waitForTimeout(40000);

  return {
    clicks,
    url: page.url(),
    title: await page.title(),
  };
}
