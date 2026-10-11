// Verification du son dans Chrome : on declenche la voix off et le bip
// directement depuis la page, et on lit l'etat de l'API + le statut de
// l'utterance (speaking = le moteur parle reellement).
export default async function run(page, ui) {
  await page.waitForSelector('flutter-view', { timeout: 60000 });
  await page.waitForTimeout(5000);

  // On attend que Chrome ait charge ses voix (asynchrone au demarrage).
  const voix = await page.evaluate(() => new Promise((res) => {
    const v = window.speechSynthesis.getVoices();
    if (v.length > 0) return res(v.map(x => `${x.name} (${x.lang})`).slice(0, 10));
    window.speechSynthesis.onvoiceschanged = () =>
      res(window.speechSynthesis.getVoices().map(x => `${x.name} (${x.lang})`).slice(0, 10));
    setTimeout(() => res(window.speechSynthesis.getVoices().map(x => `${x.name} (${x.lang})`).slice(0, 10)), 4000);
  }));

  // On fait parler le navigateur lui-meme en reutilisant la strategie du
  // code Flutter : voix fr si dispo, sinon en, sinon la premiere.
  const voixChoisie = await page.evaluate(() => {
    const liste = window.speechSynthesis.getVoices();
    if (!liste.length) return null;
    let v = liste.find(x => (x.lang || '').toLowerCase().startsWith('fr'));
    if (!v) v = liste.find(x => (x.lang || '').toLowerCase().startsWith('en'));
    if (!v) v = liste[0];
    const u = new SpeechSynthesisUtterance('DT 05 a fait une sortie de route, retourner et prendre le chemin du RomPad 2');
    u.voice = v;
    u.lang = v.lang;
    u.rate = 0.9;
    window.speechSynthesis.speak(u);
    return v.name;
  });

  // Le moteur parle-t-il reellement ?
  await page.waitForTimeout(900);
  const etat = await page.evaluate(() => ({
    speaking: window.speechSynthesis.speaking,
    pending: window.speechSynthesis.pending,
    paused: window.speechSynthesis.paused,
  }));

  return { voix, voixChoisie, etat };
}
