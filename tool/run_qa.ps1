$dir = "E:\PROJETS\VISION MINING\DB\OT V2\OT 2 - Tab - Simulation\tool"
$browser = "C:\Users\hp 640 G4\.codegpt\skills\browser-automation\browser.mjs"
node $browser "http://localhost:8123/" --session dt3 --script "$dir\qa_wait_alert.mjs" --screenshot "$dir\dt_alerte.png" --timeout 180000 *> "$dir\qa_out.log"
