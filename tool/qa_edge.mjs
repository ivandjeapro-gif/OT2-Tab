// Test de la synthese vocale dans Edge (canal msedge, headless).
// Reutilise patchright resolu comme browser.mjs, mais lance Edge.
import { createRequire } from 'node:module'
import { readdirSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

function resolveChromium() {
  const roots = []
  for (const base of [
    join(homedir(), '.vscode-server/extensions'),
    join(homedir(), '.vscode/extensions'),
  ]) {
    if (!existsSync(base)) continue
    const dirs = readdirSync(base)
      .filter((d) => d.startsWith('danielsanmedium.dscodegpt-'))
      .sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' }))
    const newest = dirs[dirs.length - 1]
    if (newest) roots.push(join(base, newest, 'standalone') + '/')
  }
  for (const root of roots) {
    try {
      const mod = createRequire(root)('patchright')
      const chromium = mod?.chromium ?? mod?.default?.chromium
      if (chromium) return chromium
    } catch {}
  }
  throw new Error('patchright introuvable')
}

const chromium = resolveChromium()
const r = {}

// 1) Edge est-il installe ?
try {
  const edgePath = chromium.executablePath('msedge')
  r.edgeExecutable = edgePath
  r.edgeInstalle = !edgePath.includes('msedge-') || edgePath.includes('msedge.exe')
} catch (e) {
  r.erreurExecutable = String(e).split('\n')[0]
  console.log(JSON.stringify(r, null, 1))
  process.exit(0)
}

// 2) Lancer Edge headless et tester speechSynthesis
const browser = await chromium.launch({
  headless: true,
  channel: 'msedge',
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
})
const page = await browser.newPage()
await page.goto('about:blank')

r.voix = await page.evaluate(() => new Promise((res) => {
  const v = window.speechSynthesis.getVoices()
  if (v.length) return res(v.map(x => `${x.name} (${x.lang})`).slice(0, 12))
  window.speechSynthesis.onvoiceschanged = () =>
    res(window.speechSynthesis.getVoices().map(x => `${x.name} (${x.lang})`).slice(0, 12))
  setTimeout(() => res(window.speechSynthesis.getVoices().map(x => `${x.name} (${x.lang})`).slice(0, 12)), 5000)
}))

// Utterance avecevenements, comme qa_son_variants
r.test = await page.evaluate(() => new Promise((res) => {
  const s = window.speechSynthesis
  const u = new SpeechSynthesisUtterance('DT 05 a fait une sortie de route, retourner et prendre le chemin du RomPad 2')
  const liste = s.getVoices()
  let v = liste.find(x => (x.lang || '').toLowerCase().startsWith('fr'))
  if (!v) v = liste.find(x => (x.lang || '').toLowerCase().startsWith('en'))
  if (!v) v = liste[0]
  if (v) { u.voice = v; u.lang = v.lang }
  u.rate = 0.9
  let debut = null, fin = null, err = null
  u.onstart = () => { debut = Date.now() }
  u.onend = () => { fin = Date.now(); res({ onstart: true, onend: true, dureeMs: fin - debut, voix: v?.name }) }
  u.onerror = (e) => { err = String(e.error || e); res({ onstart: !!debut, err, voix: v?.name }) }
  s.speak(u)
  setTimeout(() => res({ onstart: !!debut, onend: false, speaking: s.speaking, err, timeout: true, voix: v?.name }), 6000)
}))

await browser.close()
console.log(JSON.stringify(r, null, 1))
