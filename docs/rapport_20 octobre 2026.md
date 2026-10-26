# Rapport de session — 20 octobre 2026

**Projet :** ORE Tracking — tablette hors-ligne (réseau P2P Wi-Fi / BLE) + serveur central Apps Script
**Objet :** Diagnostic BLE terrain + solution « partage de connexion » pour le hotspot

---

## 1. Contexte

Le hotspot `LocalOnlyHotspot` bloque depuis Android 13 : l'hôte accepte ses
propres connexions sortantes mais **refuse le trafic entrant de ses clients**
(filtrage voulu par Google, non contournable sans root). Mesure terrain :

```
EXC -> ap0:45210     OUVERT
DT  -> 10.19.117.93  100 % de perte, TCP refuse
```

Deux voies ont été travaillées : le **partage de connexion système**
(`TetheringManager`) et la **communication BLE directe** entre tablettes.

## 2. Partage de connexion système (`PartageConnexion.kt`)

- Nouveau gestionnaire natif `android/.../PartageConnexion.kt`, canal
  `demarrer_partage` / `etat_partage` dans `MainActivity.kt`.
- `TetheringManager.startTethering(TETHERING_WIFI)` (Android 11+). Chaque
  échec rend `ok=false` avec un motif lisible (permission privilégiée absente,
  entente opérateur, interface indisponible, restriction fabricant) — jamais
  d'exception traversant la frontière Dart.
- SSID annoncé : `ORE-EXC`, mot de passe choisi : `oretracking`.
- **Limite assumée** : certains fabricants restreignent l'API aux apps
  système ; l'app retombe alors sur `LocalOnlyHotspot` (défectueux en entrant).

## 3. Outil de diagnostic BLE (`tool/diag_ble_main.dart`)

Point d'entrée Flutter séparé (QA, non livré) pour tester la chaîne BLE réelle
sans passer par l'écran de connexion :

- **TAB3 (excavatrice)** : rôle périphérique, advertising `ORE-EXC-001`,
  `BleGateway` avec ids autorisés `DT-01 / DT-02 / 1501`, diffusion d'un
  événement test `DIAG_BLE` dès l'authentification d'un DT, supervision RSSI
  toutes les 5 s.
- **TAB2 (DT)** : `BleClient` central, scan, connexion, handshake, ACK
  automatique de chaque événement reçu, reconnexion automatique toutes les 5 s.
- Tout le dialogue passe au `logcat` (tag `OREBLE`), lisible par
  `adb logcat -s OREBLE` sur chaque tablette.
- Rôle et identité passés par intent :
  `adb -s <serie> shell am start -n com.oretracking.ore_tracking/.MainActivity --es oret_diag_role TAB3`

## 4. Relais natif des arguments d'intent (`MainActivity.kt`)

Flutter n'expose pas les extras d'intent de `am start` : ajout du canal
`oret/diag` (méthode `args`) qui retourne les extras préfixés `oret_diag_`.
Inactif pour l'application normale.

## 5. Résultats du jour (21 octobre)

1. ✅ **Build + installation du diagnostic** (`flutter build apk --debug
   -t tool/diag_ble_main.dart`). Leçon de build : après modification d'un
   `tool/*.dart`, Flutter réutilise le `kernel_blob.bin` en cache — la preuve
   (grep du blob dans l'APK) et le contournement :
   `Remove-Item build\app\intermediates\flutter` avant de rebuilder.
2. ✅ **TAB3 vérifiée seule** (Active7NEU003765) : arguments d'intent reçus
   via `oret/diag`, permissions BLE accordées, gateway démarré (3 appareils
   autorisés), advertising **réellement émis** (`dumpsys bluetooth_manager`
   montre le nom local `ORE-EXC-001`).
3. ❌ **`demarrer_partage` REFUSÉ sur Android 15 / Active 7** :
   `TetheringManager` répond `TETHER_ERROR_NO_CHANGE_TETHERING_PERMISSION`
   (code 14, [doc Android](https://developer.android.com/reference/android/net/TetheringManager))
   — `TETHER_PRIVILEGED` n'est pas accordable aux apps ordinaires. Le partage
   piloté par l'app est **impossible sur ce matériel**.
4. 🔲 **Test complet du lien BLE** (TAB3 + TAB2 simultanément) : à faire dès
   que la deuxième tablette est branchée. La chaîne à vérifier est :
   advertising → scan → handshake → `DIAG_BLE` → ACK retour (tag `OREBLE`).
5. 🔲 Conséquence du refus du tethering : la voie Wi-Fi excavatrice → DT ne
   peut être ouverte que **manuellement dans les Réglages** (une fois, le
   réseau est mémorisé) ; le **BLE devient la voie principale** P2P.
6. 🔲 Rappel CDC restant : reconnexion BLE auto côté TAB 3, détection d'écart
   sur l'écran Excavator, validation terrain des 3 tablettes.

---

## 6. Test du lien BLE à deux (21 octobre, matinée)

Chaîne testée : TAB3 = Active7NEU003765 (excavatrice), TAB2 = Active7NEU000169
(DT), diagnostic installé sur les deux, radios réinitialisées avant chaque
essai.

**Ce qui fonctionne désormais :**
- advertising `ORE-EXC-001` émis et vu en scan à **-28/-29 dBm**, nom remonté
  (le rôle `SCAN` du diagnostic l'a prouvé, puis le DT l'a revu) ;
- **connexion GATT établie** : TAB3 voit le DT se connecter ;
- **écriture du handshake reçue** : 92 octets sur `0000FE5B…` (la bonne
  caractéristique RX) délivrés au callback natif du plugin.

**Deux défauts corrigés au passage :**
- comparaison d'UUID rendue insensible à la casse dans
  `transport_peripherique.dart` (le plugin retourne l'UUID en majuscules,
  les constantes sont en minuscules — l'écriture du client était rejetée) ;
- rétention des messages du lien périphérique jusqu'au premier écouteur
  (`onListen` rejoue la file) pour la course `liensEntrants` → `messages` du
  gateway. Tests banc : 7/7.

**Le point restant, mis en évidence mais non résolu :** le scan central est
**instable d'une exécution à l'autre** — parfois `ORE-EXC-001` vu en une
seconde, parfois aucun résultat en dix secondes alors que l'advertising
tourne. Quand le scan rate, le DT ne tente jamais la connexion et la chaîne
s'arrête là. Suspects : démarrage du scan trop proche du cycle
disable/enable du Bluetooth, ou comportement du filtre `withServices` sous
Android 15. Piste pour la suite : délai de stabilisation avant le premier
scan, et test du scan sans filtre de service avec filtrage applicatif (nom
ou UUID vérifié dans le code Dart).

---

## 7. Application de la piste — LIEN BLE VALIDÉ (21 octobre, 09:39)

Les correctifs suivants ont été appliqués puis **testés avec succès sur les
deux tablettes** :

1. **Scan sans filtre de service** (`transport_central.dart`) :
   `scanForDevices(withServices: [])` — le filtre UUID rate l'excavatrice de
   façon intermittente sous Android 15 ; le scan non filtré la voit en
   0,8 s. Filtrage applicatif par préfixe `ORE-EXC` dans le Dart.
2. **Identité dupliquée en données fabricant** (`transport_peripherique.dart`) :
   `ManufacturerData(0xFFF0, "ORE-EXC")` dans la trame d'advertising
   **principale** (pas la SCAN_RSP, qui n'est pas toujours remontée).
3. **Casse des UUID** : comparaison insensible dans le callback d'écriture
   (le plugin renvoie `0000FE5B-...` en majuscules).
4. **Rétention des messages** du lien périphérique : rejoués au premier
   écouteur (course `liensEntrants` → `messages` du gateway).

**Résultat du test de bout en bout (logs `OREBLE`) :**

```
TAB2 : scan vu "ORE-EXC-001" rssi=-30        (0,8 s après le début du scan)
TAB2 : CONNECTE et authentifie               (handshake accepté)
TAB3 : BLE DT-01 connecte (role ROLE_TAB2, RSSI -31)
TAB3 : evenement diag-1 diffuse
TAB2 : event recu diag-1 (DIAG_BLE)          (reçu par le DT)
TAB3 : BLE ACK recu de DT-01 pour diag-1     (ACK remonté, file purgée)
```

La chaîne complète — advertising → scan → handshake authentifié → événement
→ ACK retour — fonctionne entre deux tablettes Active 7 en Android 15.
Tests banc : 14/14 (BLE + chaîne Wi-Fi), `dart analyze lib` : zéro erreur.

---

*Fichiers concernés : `android/app/src/main/kotlin/.../PartageConnexion.kt`,
`android/app/src/main/kotlin/.../MainActivity.kt` (canal `oret/diag`),
`tool/diag_ble_main.dart`.*
