// Capture une sequence pendant la fenetre d'alerte du scenario offroad.
//
// Le scenario etant boucle et dure ~52 s, on prend une image toutes les 8 s
// pendant ~64 s : au moins une tombe pendant le passage hors parcours, cadre
// rouge clignotant. L'outil n'ecrit qu'une capture par invocation, donc le
// script prend les images lui-meme, dans le dossier de sortie.
export default async function run(page, ui) {
  await page.setViewportSize({ width: 1280, height: 800 });

  const dir = 'E:\\PROJETS\\VISION MINING\\DB\\OT V2\\OT 2 - Tab - Simulation\\tool';
  const prises = [];
  for (let i = 0; i < 8; i++) {
    await page.waitForTimeout(8000);
    const nom = `${dir}\\seq_${String(i).padStart(2, '0')}.png`;
    await page.screenshot({ path: nom });
    prises.push(nom);
    // Etat de l'ecran a cet instant : le bandeau d'alerte est un canvas, on
    // ne peut pas lire le texte. On note seulement le temps ecoule.
  }
  return { prises, url: page.url() };
}
