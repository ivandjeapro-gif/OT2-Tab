# Rapport d'avancement — Profil EXCAVATOR

**Date :** 14/10/2026 · **Version :** 1.0.0+1 · **Projet :** ORE Tracking — tablette hors-ligne (réseau P2P Wi-Fi Direct / BLE) + serveur central Apps Script

**Périmètre de ce rapport :** le seul profil EXCAVATOR (tablette de l'excavatrice — TAB 3).

---

## 1. État du profil EXCAVATOR — 6/10

### 1.1 Fait ✅

1. **Écran Excavator opérationnel** (`lib/screens/excavator_screen.dart`) — écran purement lecture, structuré autour du shell de profil commun (`ProfileShell`) :
   - bandeau d'en-tête : badge 4G à gauche (`GsmStatusBadge(etat: session.etat4G)`), nom de l'appareil au centre (`session.deviceName`, repli sur `profile.titre`), puis à droite `BleStatusBadge(etat: session.etatBle)` et `GpsStatusBadge(etat: session.etatGps)` ;
   - ligne d'état de la session perle : `session.dtConnecte.isEmpty ? 'Aucun DT dans le rayon' : 'DT <id> · <n> position(s)'` ;
   - tableaux **Easting / Northing / Elevation** branchés sur `session.easting`, `session.northing`, `session.elevation` ;
   - tableaux **Xmoy / Ymoy / Zmoy** (moyenne de la perle sur la session) : lit `session.moyennePerle`, tirets « — » tant qu'aucune position n'est accumulée ;
   - responsive : `MiseEnPage.depuis(context)` + `SingleChildScrollView` + `IntrinsicHeight`, rendu identique en paysage tablette.
2. **Chaîne GNSS complète** — `ServicePosition` créé à l'ouverture de la base (`Session.ouvrirBase`), abonnement aux mesures posé **avant** le démarrage (aucune mesure perdue), redémarrage à chaud par `Session._redemarrerGps()` quand la cadence ou le filtre changent dans Paramètres.
3. **Traitement de chaque mesure** (`Session.traiterMesure`) — détection d'écart, calcul de progression, mise à jour de `easting` / `northing` / `elevation`, notification systématique pour repeindre les tableaux à chaud.
4. **Paramètres relus en direct** depuis `meta` (`intervalle_gps_s`, `filtre_distance_gps_m`, `seuil_entree_m`, `seuil_sortie_m`, `delai_confirmation_s`) via `rechargerParametres()` — aucun redémarrage d'application nécessaire.
5. **Badge GPS** (`etatGps`) — vert dès la première mesure, orange en acquisition, rouge si le service est arrêté ou n'a jamais pu s'abonner.
6. **Gateway BLE TAB 3 (excavatrice) → DT TAB 2 (client)** — rôle choisi par `profil.roleCdc` dans `Session.demarrerBle()` (Voie 1 — inversion des rôles) : **TAB 3 est le gateway émetteur**, `BleGateway` sur `TransportBlePeripherique()` (ble_peripheral), avec l'advertising `ORE-EXC*` lancé par le transport (`demarrerPublicite()`) ; **TAB 2 (DT) est le client**, `BleClient` sur `TransportBleCentral()` (flutter_reactive_ble), qui se connecte à `ORE-EXC` et s'authentifie par handshake.
   - Côté TAB 3 : `gateway.idsAutorises` = identifiants enrôlés pour `ROLE_TAB2` ; rayon de connexion appliqué en **filtrage** au handshake (`rayon_connexion_m`, lecture seule côté plugin — pas de plafonnement à l'émission) ; `gateway.surConnexion = ouvrirSessionPerle` / `surDeconnexion = fermerSessionPerle` : **c'est le gateway de l'excavatrice qui ouvre et ferme les sessions perle** (entrée/sortie de rayon = « prêt et chargé » / « décollage », §2.3).
7. **Réception, journalisation et acquittement BLE côté TAB 3** — `gateway.surEvenement` : `base.evenementRecu(evenement)` + `push('BLE evenement recu de <source> : <event_type>')` puis `gateway.acquitter(source, event_id)`. La flèche `envoiBleActif` suit la file **du client DT** (`client.fileAttente`), alimentée par `client.surAck` : « BLE ACK recu - <eventId> synchronise ».
8. **Badge BLE** (`etatBle`) — rouge = couche non démarrée, orange = démarrée sans lien, vert = au moins un lien authentifié ; `liensBle` est lu directement sur le gateway (TAB 3) / le client (TAB 2), pas sur un compteur parallèle.
9. **Persistance et reprise** — file locale + idempotence `event_id` : rien n'est perdu après une coupure du lien BLE ; les événements reçus par le gateway sont re-stockés localement (`evenementRecu`), y compris `POSITION_PERLE` et `MOYENNE_PERLE` (`base_locale.dart:1034` et `:1054`).

### 1.2 Reste à faire 🔲

1. **Alerte hors-parcours absente de l'écran Excavator** — le moteur existe et fonctionne côté DT (`Session.traiterMesure` → `DetecteurEcart` + `AlerteMetier`), mais aucun bandeau d'alerte n'est branché ici.
2. **Aucun bouton d'action** — pas d'envoi manuel, pas de validation d'affectation, pas de démarrage/fin de cycle depuis l'écran : il est purement lecture.
3. **Pas de carte de suivi** ni de position sur plan, contrairement à l'écran DT.
4. **Cycles de chargement (début/fin, tonnage)** — présents dans le modèle mais non branchés sur l'écran.
5. **Interface de validation/consommation de l'affectation reçue** — non finalisée.
6. **Reconnexion automatique BLE** — `demarrerReconnexionAuto()` n'existe que pour le client Wi-Fi (`wifi_gateway.dart:326`, REQ-008) ; le **client BLE du DT (TAB 2)** n'a pas d'équivalent câblé (`BleClient.connecter()` ne boucle pas). Côté TAB 3 le problème ne se pose pas : l'excavatrice est le gateway, elle ne se reconnecte à personne.
7. **Validation terrain du rôle périphérique GATT** (`transport_peripherique.dart`) — testé en banc, pas en conditions réelles.
8. **Tests terrain** — 3 tablettes en conditions réelles, portée/latence BLE réelles.
9. **Déploiement serveur réel** — CONFIG (IDs Spreadsheet/Drive, jeton) non renseignée, données de production non injectées.
10. **Durcissement final** — permissions runtime à chaud, purge/rotation de la base locale, préparation de l'APK de production.

---

## 2. Chaîne de données alimentant l'écran (profil Excavator)

1. **Service de position (§5)** — `ServicePosition` créé à l'ouverture de la base (`Session.ouvrirBase`), abonnement posé avant le démarrage, redémarré à chaud par `_redemarrerGps()`.
2. **Traitement de chaque mesure** (`Session.traiterMesure`) — détection d'écart, calcul de progression, mise à jour de `easting`/`northing`/`elevation`, notification systématique pour repeindre les tableaux.
3. **Paramètres relus en direct** depuis `meta` — aucun redémarrage d'application nécessaire.
4. **Badge GPS** (`etatGps`) — vert dès la première mesure, orange en acquisition, rouge si le service est arrêté ou n'a jamais pu s'abonner.

---

## 3. Couche BLE — rôle de TAB 3 (excavatrice = gateway émetteur)

> **Correction du 15/10/2026** — la version 1.0 de ce rapport décrivait TAB 3 comme *client* BLE et TAB 2 comme *gateway*. Le code dit l'inverse (« Voie 1 — inversion des rôles », commentaires de `lib/state/session.dart:956-996`). Cette section est réécrite d'après le code réel.

1. **Rôle choisi par `profil.roleCdc`** (`Session.demarrerBle()`, lignes 1020-1096) : TAB 3 → **`BleGateway`** sur `TransportBlePeripherique()` (ble_peripheral), advertising `ORE-EXC*` ; TAB 2 → **`BleClient`** sur `TransportBleCentral()` (flutter_reactive_ble).
2. **Côté TAB 3 — la passerelle émettrice** : `TransportBlePeripherique.demarrerPublicite()` est appelé au démarrage ; le gateway accepte les DT entrés dans `rayonConnexionM` (`meta.rayon_connexion_m`, défaut 10 m), refusés au handshake au-delà. Chaque événement reçu est enregistré en base (`evenementRecu`) puis acquitté (`gateway.acquitter`).
3. **Sessions perle pilotées par le gateway** : `gateway.surConnexion = ouvrirSessionPerle` (entrée de rayon = DT « prêt et chargé »), `gateway.surDeconnexion = fermerSessionPerle` (sortie de rayon = « décollage », moyenne gelée puis remise à zéro, §2.3).
4. **Acquittements et flèche** : côté TAB 2, `client.surAck` pousse « BLE ACK recu - <eventId> synchronise » et pilote `envoiBleActif` (file `client.fileAttente`). Côté TAB 3, il n'y a pas d'ACK à attendre : la passerelle acquitte.
5. **Badge BLE** (`etatBle`) — rouge = couche non démarrée, orange = démarrée sans lien, vert = au moins un lien authentifié ; `liensBle` lu directement sur le gateway (TAB 3) / le client (TAB 2). Supervision RSSI par timer 5 s (`rafraichirRssi()`, `tab3Connectes`).
6. **À faire** — reconnexion automatique BLE côté **client DT (TAB 2)** : `demarrerReconnexionAuto()` n'existe que pour le client Wi-Fi ; `BleClient.connecter()` ne boucle pas.
7. **À faire** — validation terrain du rôle périphérique GATT (`transport_peripherique.dart`) : testé en banc, pas en conditions réelles.

---

## 4. Synthèse en 10 points — fait / reste à faire (profil Excavator)

1. ✅ **Écran Excavator opérationnel** : bandeau badges, compteurs E/N/Z et moyenne perle branchés sur les mesures GNSS réelles, responsive par `MiseEnPage`.
2. ✅ **Chaîne GNSS complète** : `ServicePosition` → `traiterMesure` → tableaux + progression, paramétrable à chaud depuis l'écran Paramètres.
3. ✅ **Lien BLE TAB 3 ↔ TAB 2** : TAB 3 = **gateway émetteur** (`BleGateway` + `TransportBlePeripherique`, advertising `ORE-EXC*`), TAB 2 = **client** (`BleClient` + `TransportBleCentral`). Côté excavatrice : réception, journalisation, acquittement et ouverture/fermeture des sessions perle par le gateway ; badge d'état fiable.
4. ✅ **Persistance et reprise** : file locale + idempotence `event_id`, rien n'est perdu après coupure du lien BLE.
5. 🔲 **Workflow métier excavatrice incomplet** : cycles de chargement et tonnage présents dans le modèle mais non branchés ; validation d'affectation non finalisée.
6. 🔲 **Alerte hors-parcours absente de l'écran Excavator** : le moteur existe et fonctionne côté DT, l'affichage n'est pas relié ici.
7. 🔲 **Reconnexion BLE automatique** non câblée sur le **client BLE du DT (TAB 2)** (seul le client Wi-Fi dispose de `demarrerReconnexionAuto`, `wifi_gateway.dart:326`).
8. 🔲 **Tests terrain** : 3 tablettes en conditions réelles, portée/latence BLE réelles, rôle périphérique GATT non validé hors banc.
9. 🔲 **Déploiement serveur réel** : CONFIG (IDs Spreadsheet/Drive, jeton) non renseignée, données de production non injectées.
10. 🔲 **Durcissement final** : permissions runtime à chaud, purge/rotation de la base locale, préparation de l'APK de production.

---

## 5. Conclusion

Le profil **EXCAVATOR** est fonctionnel en banc/développement sur son cœur : l'écran affiche les compteurs GNSS réels et la moyenne de la perle, la chaîne de position est complète et paramétrable à chaud, et le lien BLE TAB 3 ↔ TAB 2 (excavatrice = gateway émetteur, DT = client) reçoit les événements, les journalise et les acquitte. Le reste concerne le **workflow métier** (cycles de chargement, tonnage, validation d'affectation), l'**affichage de l'alerte hors-parcours**, la **reconnexion BLE automatique du client DT** et la **validation terrain / déploiement**.

**Note actuelle : 6/10** — socle lecture + GNSS + BLE complet, workflow métier de fin de cycle et validation terrain manquants.

---

*Notes d'évaluation : la note reflète l'état du code du profil Excavator (fonctionnel en banc/développement) avant les étapes de workflow métier, de tests terrain et de déploiement.*

---

## 6. Feuille de route vers 10/10 (profil Excavator)

Chaque point est numéroté selon sa source, avec l'écart constaté dans le code et le livrable attendu. Les points P1/P2 sont bloquants pour la note ; P3/P4 ferment le socle ; P5/P6 conditionnent la mise en production.

### P1 — Workflow métier excavatrice (bloquant, 6/10 → 8/10)

| # | Écart constaté | Livrable attendu |
|---|---|---|
| 1 | Aucun bouton d'action sur `excavator_screen.dart` : l'écran est purement lecture (pas d'envoi manuel, pas de validation d'affectation, pas de début/fin de cycle) | Boutons d'action branchés sur la session (envoi manuel de la file, validation d'affectation) |
| 2 | Cycles de chargement (début/fin, tonnage) absents de l'écran. Le modèle sait déjà produire `POSITION_PERLE` (`base_locale.dart:1034`) et `MOYENNE_PERLE` (`:1054`) : la moyenne est gelée à la sortie de zone (`session.dart:837`) | Écran de cycle : ouverture/fermeture depuis l'excavatrice, affichage du tonnage, envoi de la moyenne gelée au serveur |
| 3 | Interface de validation/consommation de l'affectation reçue non finalisée — `affectationRecue` (`session.dart:880`) et `horodatageAffectation` (`:883`) existent, aucun bandeau ne les affiche côté excavator (le DT en a un : `dt_screen.dart:295`) | Bandeau d'affectation (destination, dumping area, horodatage de validation) sur l'écran excavator |
| 4 | Alerte hors-parcours : le moteur tourne (`traiterMesure` → `DetecteurEcart` + `AlerteMetier`) mais rien n'est branché sur l'écran excavator | Bandeau d'alerte + bip/vibration sur l'écran excavator, sur le modèle du DT (`dt_screen.dart:227`, `:785-793`) |
| 5 | Pas de carte de suivi ni de position sur plan (le DT utilise `CarteSuivi`, `dt_screen.dart:126`) | Carte de suivi de la perle / du DT sur l'écran excavator |

### P2 — Reconnexion BLE automatique du client DT (bloquant, 8/10 → 9/10)

| # | Écart constaté | Livrable attendu |
|---|---|---|
| 6 | `demarrerReconnexionAuto()` n'existe que sur `WifiClient` (`wifi_gateway.dart:326`, REQ-008). `BleClient.connecter()` (`ble_gateway.dart:305`) rend `false` si `ORE-EXC` est absent et ne relance rien | Boucle de reconnexion côté `BleClient` (timer + re-scan), sur le modèle de `WifiClient._surveiller()`, avec rappel de `_retransmettreFileBle()` dès que le lien redevient vert |
| 7 | Validation terrain du rôle périphérique GATT (`transport_peripherique.dart`) : testé en banc seulement | Campagne de validation sur 3 tablettes réelles : portée, latence, tenue de l'advertising Android, multi-connexions |

### P3 — Déploiement serveur réel (9/10 → 9,5/10)

| # | Écart constaté | Livrable attendu |
|---|---|---|
| 8 | CONFIG (IDs Spreadsheet/Drive, jeton) non renseignée ; `diagnosticSante()` (`transmetteur.dart:482`) et son test (`test/transmetteur_sante_test.dart`) sont prêts mais jamais exécutés contre le vrai déploiement | CONFIG renseignée, `diagnosticSante()` vert sur le déploiement réel, données de production injectées |
| 9 | Chaîne complète tablette → Apps Script non validée de bout en bout (le rapport SPOTTER signale le même écart) | Test de bout en bout : événement `POSITION_PERLE` / `MOYENNE_PERLE` parti de TAB 3, acquitté côté DT, remonté au serveur |

### P4 — Durcissement final (9,5/10 → 10/10)

| # | Écart constaté | Livrable attendu |
|---|---|---|
| 10 | Permissions runtime : BLE traité (`permissions_ble.dart:46`, appelé en `session.dart:1016`) et caméra/galerie à chaud côté spotter (`spotter_screen.dart:90-109`, via `PermissionsPhoto`) ; reste le contrôle de refus définitif côté écran | Message « ne plus demander » + renvoi vers les réglages système sur chaque écran concerné |
| 11 | Base locale : pas de purge/rotation (`evenements` PENDING s'accumulent indéfiniment) | Purge des événements `SYNCED` au-delà d'un seuil + rotation documentée |
| 12 | Couverture de tests faible : 2 fichiers seulement (`test/diag_ecrans_test.dart`, `test/transmetteur_sante_test.dart`) | Tests unitaires sur `BleClient`/`BleGateway` (ACK, file PENDING), `SessionPerle` (moyenne/gel), `PermissionsPhoto`, plus tests d'écran par profil |
| 13 | APK de production non préparé | Build release signé, minification, vérification des permissions du manifeste, procédure d'installation tablette |

### Ordre recommandé

1. **P1.4 — alerte hors-parcours** (le moteur existe, c'est le moins coûteux et le plus visible sur le terrain).
2. **P1.2 — cycles de chargement / tonnage** (cœur métier de l'excavatrice, s'appuie sur `MOYENNE_PERLE` déjà en place).
3. **P2.6 — reconnexion BLE automatique** (fiabilise le lien terrain sans intervention de l'opérateur).
4. **P1.3 / P1.5 / P1.1** (bandeau d'affectation, carte de suivi, boutons d'action).
5. **P2.7 — validation terrain** puis **P3 — serveur réel**, **P4 — durcissement**.

*Notes : les points 6 et 7 concernent le couple TAB 2 / TAB 3 — la correction de la section 3 (rôle BLE inversé) n'allège pas la note actuelle, elle évite d'attendre de l'excavatrice une fonctionnalité (client, envoi de file, ACK) qui appartient au DT.*
