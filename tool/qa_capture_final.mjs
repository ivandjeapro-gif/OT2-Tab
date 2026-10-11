// Capture finale : alerte offroad figee (mode presentation).
//
// Le scenario reste au point d'ecart maximal : une fois l'alerte declenchee
// (~30 s de chargement + ~15 s sur le parcours + ~17 s de detour), elle ne
// retombe plus. On attend 65 s pour etre franchement dedans, puis on capture
// deux images a 1,2 s d'ecart : la premiere pour le rendu, la seconde pour
// prouver que le cadre clignote (les deux doivent differer sur l'opacite).
export default async function run(page, ui) {
  await page.setViewportSize({ width: 1280, height: 800 });
  const dir = 'E:\\PROJETS\\VISION MINING\\DB\\OT V2\\OT 2 - Tab - Simulation\\tool';

  await page.waitForTimeout(65000);
  await page.screenshot({ path: `${dir}\\final_a.png` });
  await page.waitForTimeout(1200);
  await page.screenshot({ path: `${dir}\\final_b.png` });

  return { url: page.url(), title: await page.title() };
}
