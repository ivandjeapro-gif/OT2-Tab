export default async function run(page, ui) {
  const out = { steps: [] };
  // 1) Attendre l'app Flutter.
  await page.waitForSelector('flutter-view', { timeout: 60000 });
  await page.waitForTimeout(7000);
  out.steps.push('app mounted');

  // 2) Capture AVANT clic.
  await page.screenshot({ path: 'E:\\PROJETS\\VISION MINING\\DB\\OT V2\\OT 2 - Tab - Simulation\\tool\\demo_login.png' });
  out.steps.push('login screenshot saved');

  // 3) Sonde la sémantique Flutter ; si vide, l'activer via le bouton dédié.
  const probe1 = await page.evaluate(() => {
    const cands = [...document.querySelectorAll('flt-semantics[role=button], [aria-label]')];
    return cands.map(e => ({ tag: e.tagName, label: e.getAttribute('aria-label'), role: e.getAttribute('role') }));
  });
  out.semantics = probe1;
  if (probe1.length <= 1) {
    await page.evaluate(() => {
      const btn = document.querySelector('[aria-label="Enable accessibility"]');
      if (btn) btn.click();
    });
    await page.waitForTimeout(3000);
    out.semanticsAfter = await page.evaluate(() => {
      return [...document.querySelectorAll('flt-semantics[role=button]')].map(e => e.getAttribute('aria-label'));
    });
  }

  // 4) Chercher et cliquer le bouton "DT".
  const dtLabel = (out.semanticsAfter || []).find(l => /DT/.test(l || '')) || (out.semantics || []).map(s => s.label).find(l => /DT/.test(l || ''));
  out.dtLabel = dtLabel || null;
  if (dtLabel) {
    await page.evaluate(() => {
      const btns = [...document.querySelectorAll('flt-semantics[role=button]')];
      const btn = btns.find(e => /DT/.test(e.getAttribute('aria-label') || ''));
      btn?.click();
    });
    await page.waitForTimeout(9000);
    out.steps.push('clicked DT');
    await page.screenshot({ path: 'E:\\PROJETS\\VISION MINING\\DB\\OT V2\\OT 2 - Tab - Simulation\\tool\\demo_dt.png' });
    out.steps.push('dt screenshot saved');
  } else {
    out.steps.push('no DT button found');
  }

  return out;
}
