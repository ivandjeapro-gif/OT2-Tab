export default async function run(page, ui) {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto('http://localhost:8765', { waitUntil: 'load' });
  await page.waitForTimeout(25000);
  await page.screenshot({ path: 'e:/PROJETS/VISION MINING/DB/OT V2/OT 2 - Tab/verif.png', fullPage: false });
  return 'ok';
}
