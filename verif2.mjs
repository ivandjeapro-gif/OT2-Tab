export default async function run(page, ui) {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto('http://localhost:8765', { waitUntil: 'load' });
  // Attendre que le canvas Flutter soit reellement peint (2 frames stables).
  await page.waitForFunction(() => {
    const c = document.querySelector('flt-glass-pane');
    return c && c.getBoundingClientRect().height > 400;
  }, { timeout: 60000 });
  await page.waitForTimeout(4000);
  await page.screenshot({ path: 'e:/PROJETS/VISION MINING/DB/OT V2/OT 2 - Tab/verif.png', fullPage: false });
  return 'ready';
}
