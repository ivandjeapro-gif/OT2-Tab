// Test des 3 variantes d'utterance pour trouver celle qui sort du son.
export default async function run(page, ui) {
  await page.waitForSelector('flutter-view', { timeout: 60000 });
  await page.waitForTimeout(3000);

  const r = {};
  const variantes = [
    ['sans_lang', (u) => {}],
    ['lang_fr', (u) => { u.lang = 'fr-FR'; }],
    ['rate_1', (u) => { u.rate = 1; }],
  ];

  for (const [nom, cfg] of variantes) {
    const res = await page.evaluate(([n, cfg]) => {
      return new Promise((res) => {
        const s = window.speechSynthesis;
        s.cancel();
        const u = new SpeechSynthesisUtterance('Test ' + n + ' un deux trois');
        cfg(u);
        let debut = null, fin = null, err = null;
        u.onstart = () => { debut = Date.now(); };
        u.onend = () => { fin = Date.now(); res({ onstart: true, duree: fin - debut }); };
        u.onerror = (e) => { err = String(e.error || e); res({ onstart: false, err }); };
        s.speak(u);
        setTimeout(() => res({ onstart: !!debut, speaking: s.speaking, err, timeout: true }), 4000);
      });
    }, [nom, cfg]);
    r[nom] = res;
    await page.waitForTimeout(500);
  }

  r.voix = await page.evaluate(() => window.speechSynthesis.getVoices().length);
  return r;
}
