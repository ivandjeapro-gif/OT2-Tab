# Rapport d'avancement — ORE Tracking

**Date :** 14/10/2026 · **Version :** 1.0.0+1 · **Projet :** Application tablette hors-ligne (réseau P2P Wi-Fi Direct / BLE) + serveur central Apps Script

**Profil suivi :** EXCAVATOR (TAB 3 — excavatrice)

---

## 1. Écran Excavator — état réel du code

Écran de l'excavatrice : compteurs E/N/Z rafraîchis à chaque mesure GNSS, moyenne de la perle sur la session, badges d'état réseau/capteurs.

### 1.1 Ce qui est affiché (`lib/screens/excavator_screen.dart`)

1. **Fait** — `ProfileShell` + `ListenableBuilder(session)` : l'écran se repeint à chaque `notifyListeners()` de la session, donc à chaque mesure GPS (voir `Session.traiterMesure`).
2. **Fait** — Bandeau d'en-tête : badge 4G à gauche (`GsmStatusBadge(etat: session.etat4G)`), nom de l'appareil au centre (`session.deviceName`, repli sur `profile.titre`), puis à droite `BleStatusBadge(etat: session.etatBle)` et `GpsStatusBadge(etat: session.etatGps)`.
3. **Fait** — Ligne d'état de la session perle : `session.dtConnecte.isEmpty ? 'Aucun DT dans le rayon' : 'DT <id> · <n> position(s)'` — remplace l'ancien « Synchro #n » dès que la couche BLE est inversée côté excavator.
4. **Fait** — Tableau **Easting / Northing / Elevation** : en-tête sur fond `AppColors.tan`, valeurs sur fond blanc en serif 72*k, relié à `session.easting`, `session.northing`, `session.elevation`.
5. **Fait** — Tableau **Xmoy / Ymoy / Zmoy** (moyenne de la perle sur la session, §2.3) : lit `session.moyennePerle`, tirets « — » tant qu'aucune position n'est accumulée. C'est cette moyenne qui doit être envoyée au serveur à la sortie de zone.
6. **Fait** — Responsive : `MiseEnPage.depuis(context)` + `SingleChildScrollView` + `IntrinsicHeight` — en paysage large et bas le tableau défile au lieu de déborder, rendu identique en paysage tablette.

### 1.2 Ce qui reste à faire côté écran Excavator

1. 🔲 **Aucun bandeau d'alerte hors-parcours** sur cet écran : la détection d'écart et le bip/vibration sont câblés côté DT (`Session.traiterMesure` → `DetecteurEcart` + `AlerteMetier`), l'écran excavator n'affiche rien de tel.
2. 🔲 **Aucun bouton d'action** : pas d'envoi manuel, pas de validation d'affectation, pas de démarrage/fin de cycle depuis l'écran — il est purement lecture.
3. 🔲 **Pas de carte de suivi** ni de position sur plan, contrairement à l'écran DT.

---

## 2. Chaîne de données alimentant l'écran (profil Excavator)

1. **Fait** — Service de position (§5) : `ServicePosition` créé à l'ouverture de la base (`Session.ouvrirBase`), abonnement aux mesures posé **avant** le démarrage, redémarré à chaud par `_redemarrerGps()` quand la cadence/filtre changent dans Paramètres.
2. **Fait** — Traitement de chaque mesure (`Session.traiterMesure`) : détection d'écart, calcul de progression, mise à jour de `easting`/`northing`/`elevation`, notification systématique pour repeindre les tableaux.
3. **Fait** — Paramètres relus en direct depuis `meta` (`intervalle_gps_s`, `filtre_distance_gps_m`, `seuil_entree_m`, `seuil_sortie_m`, `delai_confirmation_s`) via `rechargerParametres()` — aucun redémarrage d'application nécessaire.
4. **Fait** — Badge GPS (`etatGps`) : vert dès la première mesure, orange en acquisition, rouge si le service est arrêté ou n'a jamais pu s'abonner.

---

## 3. Couche BLE — rôle de TAB 3 (excavatrice = client)

1. **Fait** — `Session.demarrerBle()` choisit le rôle par `profil.roleCdc` : TAB 3 → `BleClient` sur `TransportBleCentral()` (flutter_reactive_ble) ; TAB 2 → `BleGateway` sur `TransportBlePeripherique()` (ble_peripheral).
2. **Fait** — Côté TAB 3 : création du client avec `sourceDevice` `TAB3-<deviceId>`, connexion, puis `_retransmettreFileBle()` automatique dès que le lien est authentifié (§9) — la file PENDING part sans action utilisateur.
3. **Fait** — Acquittements : `client.surAck` pousse « BLE ACK recu - <eventId> synchronisé » et pilote `envoiBleActif` (animation de la flèche tant que `fileAttente` n'est pas vide).
4. **Fait** — Badge BLE (`etatBle`) : rouge = couche non démarrée, orange = démarrée sans lien, vert = au moins un lien authentifié ; `liensBle` est lu directement sur le gateway/client, pas sur un compteur parallèle.
5. **À faire** — Reconnexion automatique BLE côté TAB 3 : `demarrerReconnexionAuto()` n'existe que pour le client Wi-Fi ; le client BLE n'a pas d'équivalent câblé.
6. **À faire** — Validation terrain du rôle périphérique GATT (`transport_peripherique.dart`) : testé en banc, pas en conditions réelles.

---

## 4. Avancement du profil EXCAVATOR (noté sur 10) — 6/10

| # | Élément | État |
|---|---------|------|
| 1 | Écran excavatrice (compteurs E/N/Z + moyenne perle) | ✅ Fait |
| 2 | Service de position réel + badges GPS/4G/BLE | ✅ Fait |
| 3 | Client BLE TAB 3 → gateway TAB 2, envoi automatique de la file | ✅ Fait |
| 4 | Détection d'écart / alerte hors-parcours sur cet écran | 🔲 À faire |
| 5 | Cycles de chargement (début/fin, tonnage) | 🔲 À faire |
| 6 | Interface de validation/consommation de l'affectation reçue | 🔲 À faire |
| 7 | Reconnexion automatique BLE + validation terrain du GATT périphérique | 🔲 À faire |

---

## 5. Synthèse — fait / reste à faire

1. ✅ **Écran Excavator opérationnel** : bandeau badges, compteurs E/N/Z et moyenne perle branchés sur les mesures GNSS réelles, responsive par `MiseEnPage`.
2. ✅ **Chaîne GNSS complète** : `ServicePosition` → `traiterMesure` → tableaux + progression, paramétrable à chaud depuis l'écran Paramètres.
3. ✅ **Lien BLE TAB 3 → TAB 2** : client central, envoi automatique de la file PENDING, ACK poussés au journal, badge d'état fiable.
4. ✅ **Persistance et reprise** : file locale + idempotence `event_id`, rien n'est perdu après coupure du lien BLE.
5. 🔲 **Workflow métier excavatrice incomplet** : cycles de chargement et tonnage présents dans le modèle mais non branchés ; validation d'affectation non finalisée.
6. 🔲 **Alerte hors-parcours absente de l'écran Excavator** : le moteur existe et fonctionne côté DT, l'affichage n'est pas relié ici.
7. 🔲 **Reconnexion BLE automatique** non câblée (seul le Wi-Fi dispose de `demarrerReconnexionAuto`).
8. 🔲 **Tests terrain** : 3 tablettes en conditions réelles, portée/latence BLE réelles, rôle périphérique GATT non validé hors banc.
9. 🔲 **Déploiement serveur réel** : CONFIG (IDs Spreadsheet/Drive, jeton) non renseignée, données de production non injectées.
10. 🔲 **Durcissement final** : permissions runtime à chaud, purge/rotation de la base locale, préparation de l'APK de production.

---

*Notes d'évaluation : les notes reflètent l'état du code du profil Excavator (fonctionnel en banc/développement) avant les étapes 5 à 10 — workflows métier, tests terrain et déploiement.*
