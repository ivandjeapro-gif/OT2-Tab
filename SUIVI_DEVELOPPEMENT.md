# Suivi de développement — ORE TRACKING

## Séance du 2026-10-08

### Réalisations

1. **Couche Wi-Fi TAB 1 ↔ TAB 2 : IMPLÉMENTÉE ET TESTÉE** (REQ-007/008)
   - `lib/communication/wifi/transport_wifi.dart` : interfaces `TransportWifi` /
     `LienWifi` abstraites (mêmes principes que le BLE, CDC §29).
   - `lib/communication/wifi/wifi_protocole.dart` : JSON sur trames longueur+
     charge (préfixe 4 octets big-endian), `Deframeur` incrémental qui réassemble
     un JSON arrivé en plusieurs paquets de socket ; types HANDSHAKE/OK/KO/
     EVENEMENT/ACK/NACK/PING/PONG.
   - `lib/communication/wifi/wifi_gateway.dart` : `WifiGateway` (TAB 2 = point
     d'accès, max 5 clients, authentification REQ-017, ACK) et `WifiClient`
     (TAB 1 = spotter : découverte ORE-TAB2*, handshake, file locale non
     acquittée, reconnexion automatique périodique REQ-008, `envoyerParLien`
     pour adopter un lien déjà établi).
   - `lib/communication/wifi/banc_wifi.dart` : simulateur en mémoire,
     fragmentation TCP simulable, coupures bidirectionnelles.
   - `lib/communication/wifi/transport_tcp.dart` : **transport réel sur
     sockets** — `ServerSocket` (TAB 2, `heberger()`, port réellement écouté
     exposé), `Socket` + scan du sous-réseau par test du port applicatif
     (TAB 1), déframeur sur les paquets TCP entrants. Testé sur loopback :
     handshake + ACK bout en bout, JSON de 5 ko fragmenté par TCP réassemblé.
   - `Session.demarrerWifi(transport:)` : TAB 2 → gateway + serveur TCP par
     défaut (port 45210) si aucun transport injecté ; TAB 1 (spotter) →
     client + reconnexion auto. États UI : `wifiActif`, `clientsWifiConnectes`.
   - Tests : `test/wifi_test.dart` (11, banc), `test/transport_tcp_test.dart`
     (3, vraies sockets loopback, port 0 pour éviter les collisions en CI).

### Cible web (Chrome)

Pour pouvoir ouvrir l'app sans tablette sous la main, la cible web a été
mise en place :

- `flutter create --platforms=web .` : `web/index.html`, `manifest.json`,
  icônes. Aucun fichier existant touché (`main.dart`, `pubspec.yaml` et les
  tests sont restés intacts).
- `sqflite_common_ffi_web` : `web/sqflite_sw.js` (worker partagé) et
  `web/sqlite3.wasm` (moteur SQLite compilé en wasm) placés dans `web/`.
  ⚠️ `dart run sqflite_common_ffi_web:setup` échoue sur ce poste
  (`CERTIFICATE_VERIFY_FAILED` : le certificat racine n'est pas dans le
  magasin de Dart) — le wasm a été récupéré en `curl -k` depuis
  `github.com/simolus3/sqlite3.dart` (release sqlite3-2.9.4, 730 989 octets,
  en-tête `\0asm` vérifié) ; refaire un `--force` au moindre changement de
  version de `sqlite3`.
- `main.dart` : `if (kIsWeb) databaseFactory = databaseFactoryFfiWeb;` — la
  fabrique FFI web ouvre la même base, stockée dans IndexedDB (toujours
  `'$dossier/ore_tracking.db'`, `getDatabasesPath()` renvoie `/` sur le web).
  `dart:io` reste importé mais `Platform` n'est plus évalué sur web (const
  pliée par le compilateur, sinon `UnsupportedError`).
- `service_position.dart` : la permission runtime n'est plus testée via
  `Platform` sur web (le navigateur la porte lui-même).
- Vérifié dans Chrome headless : écran de login rendu, **zéro erreur console**,
  IndexedDB `sqflite_databases` bien écrite (store `files` + `blocks`) →
  SQLite s'ouvre et persiste côté navigateur.

### État vérification
- `flutter analyze` : 0 problème.
- `flutter test` : 82/82 verts (projet entier, y compris la zone base/HTTPS
  et les nouveaux tests de badges).
- `flutter build web` : OK (`build/web`, 47 s).

### Précision sur la liste « À FAIRE » du 07/10
- Le point 3 (HTTPS TAB 2 → serveur) était **déjà réalisé** en séance du 07/10 :
  `lib/data/synchronisation.dart` + `TransmetteurHttp` + `docs/API_SYNCHRO.md`.

### Travail en parallèle
- Un second agent travaille **en parallèle sur la base de données et la lecture
  dans celle-ci** (`lib/data/base_locale.dart` etc.). Ne pas toucher à ces
  fichiers : rester confiné à `lib/communication/wifi/`, les tests réseau, et
  au besoin `Session` uniquement pour le câblage des couches de communication.
  ⚠️ Constaté en fin de séance : `test/transmetteur_test.dart` est en désaccord
  avec `lib/data/transmetteur.dart` (signature de `meta`) — l'autre agent est
  en cours de modification, à ne pas corriger de ce côté.

### Réalisations BLE réel (suite de séance)

2. **Transports BLE réels : IMPLÉMENTÉS** (CDC §29, À FAIRE n°1 du 07/10)
   - `pubspec.yaml` : ajout `ble_peripheral: ^2.4.0` (GATT server ;
     flutter_reactive_ble n'opère qu'en central).
   - `lib/communication/ble/transport_peripherique.dart` : TAB 2 côté
     peripherique — service ORE TRACKING (UUIDs fixes FE5A/FE5B/FE5C),
     caractéristique RX (écriture client) et TX (notifications TAB 2),
     advertising nommé `ORE-TAB2-001`, création du lien à la première
     écriture du client.
   - `lib/communication/ble/transport_central.dart` : TAB 3 côté central —
     scan du service, connexion GATT, MTU 512, notifications TX, écritures RX,
     `readRssi` sur le lien.
   - **RSSI déclaré dans le handshake** : Android n'expose pas le RSSI côté
     peripherique. Le client mesure (`readRssi`, repli RSSI du scan) et met
     le champ `rssi` dans son HANDSHAKE ; le gateway le lit en priorité
     (interface `LienDeclaratif` pour mémoriser la déclaration dans le lien).
   - `Session.demarrerBle()` : transport réel par défaut selon profil
     (excavator → central, DT → peripherique + advertising). Tests toujours
     en banc injecté.
   - `AndroidManifest.xml` : ajout `BLUETOOTH_ADVERTISE` (requis API 31+).
   - Validation : analyze 0 problème, tests verts. **Non validé sur matériel
     réel** : à faire sur tablettes (deux appareils Android) — limite du banc.

3. **Reprise du dossier `transmetteur.dart`** (l'autre agent a été déchargé)
   - Le désaccord venait du **test seul** : `test/transmetteur_test.dart`
     déclarait son aide `meta()` comme renvoyant `Map<String, String>` alors
     qu'elle retourne une closure `String? Function(String)` (le type attendu
     par `TransmetteurHttp`). Signature du test corrigée — le code de la
     bibliothèque était déjà cohérent.
   - `lib/data/base_locale.dart` : migration v4 rendue **idempotente** —
     `CREATE TABLE IF NOT EXISTS affectation`. Sans cela, un fichier déjà à
     jour qui repasse par la migration (retour de version, restauration)
      explosait sur « table affectation already exists » (échec du test de
      migration v1 → v4).

4. **Badges réseau en trois états : ROUGE / ORANGE / VERT** (CDC §20/§21)
   - `lib/state/etat_couche.dart` : enum `EtatCouche { arret, recherche,
     connecte }` — une seule convention pour les quatre couches, avec
     `couleur` (rouge / orange / vert) et `libelle` (`offline` / `search` /
     `online`). `AppColors.orange` ajouté à `app_theme.dart`.
   - Sources réelles, plus aucun état simulé :
     - **Wi-Fi** (`etatWifiDevice`) : `connectivity_plus` lue par
       `Session.majConnectivite(...)` (écoute `onConnectivityChanged` **et**
       `checkConnectivity()` initial — sans ce dernier le badge restait rouge
       jusqu'à la première variation). Rouge si rien n'a été lu ou si le
       radio Wi-Fi du device est absent, orange si le radio est là sans
       session posée dessus, vert si `masterConnected`.
     - **4G** (`etat4G`) : `Transmetteur.serveurRepondu` (nouveau getter
       concret sur l'abstract, `null` = jamais tenté) — `true` dès qu'une
       réponse HTTP arrive (même 404/500), `false` sur timeout/host absent ;
       mis à jour par `envoyer` **et** `lireAffectation`. Rouge si la
       boucle `Synchronisation` n'a pas démarré ou si la voie est coupée,
       orange en attente du premier retour, vert dès que le serveur répond.
       `Synchronisation.actif` (= `_minuterie != null`) et
       `Synchronisation.serveurRepondu` exposés.
     - **BLE** (`etatBle`) / **Wi-Fi P2P** (`etatWifiP2p`) : rouge = couche
       pas démarrée, orange = démarrée et en découverte, vert dès qu'au
       moins un lien est authentifié — lu sur `gateway.clientsConnectes`
       (nouveaux getters `liensBle` / `liensWifi`, vivants) plutôt que sur
       `tab3Connectes` / `clientsWifiConnectes` (ce dernier n'était **jamais
       mis à jour** : le DT affichait toujours « 0 Spotter »).
   - `lib/widgets/status_badges.dart` : les quatre badges prennent un
     `EtatCouche` (`connected:` / `online:` / `actif:` supprimés). Le compteur
     n'apparaît qu'en vert ; en rouge/orange, `off` / `search` / `DT`.
     `SyncCloudIcon` suit `etatWifiDevice`.
   - Call sites : `dt_screen` (badges BLE et P2P **toujours visibles** pour
     le DT — rouge = « pas démarré » doit se voir), `excavator_screen`,
     `profile_shell` (`_BadgeCoucheCompact`), `supervision_reseau`
     (`_Etiquette` passe de `bool actif` à `EtatCouche`).
   - Tests : `test/etat_couche_test.dart` (9 — dérivation des quatre couches,
     dont un aller-retour HTTP réel sur `127.0.0.1` pour vérifier le vert et
     le rouge « injoignable »), `test/badges_widgets_test.dart` (4 — rendu
     couleur/libellé), + 2 tests `serveurRepondu` dans
     `test/transmetteur_test.dart`. ⚠️ Les tests HTTP réels ne doivent pas
     être dans un fichier qui utilise `testWidgets` : `TestWidgetsFlutterBinding`
     intercepte `HttpClient` et répond 400 sans rien envoyer.

### À FAIRE — prochaine séance
1. **Valider le BLE sur matériel réel** : deux tablettes Android, le code
   est prêt (central + peripherique) — permissions à accorder au premier
   lancement, calibrer les seuils RSSI (CDC §8) et la limite MTU réelle.
2. **Transport Wi-Fi réel** : fait pour les sockets TCP (`transport_tcp.dart`,
   testé sur loopback). Reste : **activation du hotspot Android** (point
   d'accès logiciel) — passera par un plugin natif, non géré par la couche.
3. **Enrôlement** : rôle verrouillé à l'installation (REQ-002), IDs type
   TAB1/TAB2/TAB3-NNN, rejeter les inconnus (la logique de rejet existe,
   l'enrôlement à l'installation reste à écrire).
4. UI des écrans : **états de couche faits** (quatre badges rouge/orange/
   vert, voir « Badges réseau en trois états » ci-dessus). Reste : liste
   TAB 3 + RSSI lisible depuis l'écran, journal §21/§22, et prévoir un
   serveur local pour la démo — **le badge 4G ne passera au vert que s'il
   reçoit une vraie réponse** (il est honnête : sans serveur, il reste orange
   puis rouge).
5. Anciennes failles de l'audit toujours ouvertes : écritures disque perdues
   (`_ecrire`/`catchError`), FK absentes (`lignes.bloc_id`), photo BLOB sans
   limite.

### Décisions de conception retenues
- Trames longueur+charge plutôt que JSON brut sur le flux : deux messages dos
  à dos sur TCP seraient indissociables, et un JSON peut arriver en deux paquets.
- Purge du tampon sur longueur aberrante (flux invalide) : on resynchronise à
  la reconnexion au lieu de bouffer la mémoire.
- Mêmes patterns que le BLE réutilisés à l'identique : s'abonner AVANT le
  handshake, file locale retransmise à la reconnexion, ACK par event_id.

## Séance du 2026-10-07

### Réalisations

1. **Audit système + lecture du CDC v1.1** (PDF à la racine du projet)
   - Diagnostic : P2P 100 % simulé ; seules la base SQLite locale et l'UI existent.
   - Conformité CDC évaluée exigence par exigence (REQ-001 à REQ-020).

2. **Couche BLE TAB 3 ↔ TAB 2 : IMPLÉMENTÉE ET TESTÉE**
   - `lib/communication/ble/ble_protocole.dart` : format CDC §12 (JSON ≤ 512 o),
     types HANDSHAKE/HANDSHAKE_OK/KO/EVENEMENT/ACK/PING,
     `ControleurProximite` : hystérésis double seuil (entrée -70 / sortie -80 dBm),
     3 mesures consécutives, `evaluerPremierContact()` pour le handshake.
   - `lib/communication/ble/transport_ble.dart` : interfaces `TransportBle` /
     `LienBle` abstraites (mockables, CDC §29).
   - `lib/communication/ble/ble_gateway.dart` : `BleGateway` (TAB 2 : multi-clients,
     max 5, authentification REQ-017, RSSI continu, ACK, journal §22)
     et `BleClient` (TAB 3 : découverte, handshake, file locale non acquittée,
     retransmission à la reconnexion REQ-013/018).
   - `lib/communication/ble/banc_ble.dart` : simulateur en mémoire
     (2 tablettes virtuelles, pannes simulées).
   - `Session.demarrerBle(transport:)` : TAB 2 → gateway, TAB 3 → client.
     États UI : `bleActif`, `tab3Connectes`, `rssiTab3`.
   - `BaseLocale.evenementRecu()` : stockage idempotent par event_id (CDC §17),
     `journalBle` exposé.
   - `pubspec.yaml` : flutter_reactive_ble ^5.3.1.
   - `AndroidManifest.xml` : BLUETOOTH_SCAN (neverForLocation), BLUETOOTH_CONNECT,
     permissions legacy + ACCESS_FINE_LOCATION.
   - `test/ble_test.dart` : 9 tests (protocole, hystérésis, handshake bout en bout,
     rejet pirate, TAB 2 absent, retransmission).

### État vérification
- `flutter analyze` : 0 problème.
- `flutter test` : 28/28 verts.

### Bugs corrigés pendant la séance
- `BleProtocole.evenement()` ne portait pas de champ `type` → ignoré par le gateway.
- Client : la réponse du handshake partait avant son abonnement au flux de
  messages → perdu, blocage. Fix : s'abonner AVANT d'envoyer le handshake
  (même pattern côté gateway dans `_accueilLien`).
- Banc : lien bidirectionnel (`_pair` posé des deux côtés), streams broadcast,
  livraison en microtask (imite le timing BLE réel).

### À FAIRE — prochaine séance
1. **Role périphérique BLE** : flutter_reactive_ble ne fait pas "server/GATT
   server" → brancher un plugin type `flutter_ble_peripheral` derrière
   `TransportBle`. Logique déjà écrite, seul le transport réel manque.
   À valider sur le matériel réel (CDC §29).
2. **Couche Wi-Fi TAB 1 ↔ TAB 2** (REQ-007/008) : point d'accès fourni par TAB 2,
   portée 40 m, reconnexion auto, retransmission.
3. **Couche HTTPS TAB 2 → serveur** (REQ-009/015/016) : consommateur de la file
   PENDING avec gateway_id, retry, ACK serveur, idempotence.
4. **Enrôlement** : rôle verrouillé à l'installation (REQ-002), IDs type TAB-001,
   rejeter les inconnus.
5. Brancher l'UI des écrans (état BLE, liste TAB 3 + RSSI, journal §21/§22) —
   les états existent dans Session mais aucun écran ne les affiche encore.
6. Anciennes failles de l'audit toujours ouvertes : écritures disque
   silencieusement perdues (`_ecrire`/`catchError`), FK absentes
   (`lignes.bloc_id`), photo BLOB sans limite, pas de vrai réseau pour
   `envoyerDonnees()`.

### Décisions de conception retenues
- Logique métier codée contre interfaces abstraites, transports injectables
  (testable au banc avant le matériel, CDC §29).
- Hystérésis symétrique (mêmes règles d'entrée/sortie) + verdict immédiat au
  premier contact GATT (un lien accepté = preuve forte de proximité).
- `gateway_id` : constante `Session.idGateway = 'TAB2-001'` pour l'instant.

## Séance du 2026-10-08 (suite) — Alertes hors-parcours (son + vibration)

### Réalisations

1. **Détection d'écart au parcours (option B, décision des deux voies)**
   - `lib/communication/position/detection_ecart.dart` : `DetecteurEcart`
     pur Dart — polyline `parcours` du serveur, distance point→segment en
     UTM, **seuils validés 40/20 m + 15 s de confirmation** (hystérésis),
     reparse seulement si la chaîne change, JSON malformé → inactif sans
     lever.
   - Repli (option A) conservé : sans `parcours`, l'état vient du champ
     `alerte` du serveur — les deux coexistent, le local a la priorité.
   - Contrat : `docs/API_SYNCHRO.md` §8 documente `parcours`
     (`[[easting, northing], …]`) et `alerte`, plus le comportement
     (affectation sans `parcours` remplace toute la table).
2. **Signal sonore + vibration à chaque mesure GPS**
   - `lib/communication/alertes/alerter.dart` : `AlerteMetier` injectable,
     `AlerteSysteme` (vibration + bip WAV `assets/sons/alerte.wav` généré,
     replis silencieux HapticFeedback/sans audio), `AlerteFactice` pour les
     tests.
   - `pubspec.yaml` : vibration ^3.1.8, audioplayers ^6.7.1 (bornés par le
     Flutter 3.35.4 / Dart 3.9.2 du poste), asset `assets/sons/`.
   - `AndroidManifest.xml` : permission `VIBRATE`.
3. **Câblage**
   - `ServicePosition.mesures` : flux broadcast des mesures GPS.
   - `Session` : `detecteurEcart` + `alerter` injecté, abonnement à chaque
     mesure (`traiterMesure`, testable), `alerteCourante` (local → serveur),
     **`alerter.jouer()` à chaque mesure pendant l'alerte**, notification au
     front montant, `fermer()` au dispose.
   - `dt_screen.dart` : `_BanniereAlerte` lit `alerteCourante` et affiche
     l'écart en mètres vers la dumping area.

### État vérification
- `flutter analyze` : 0 problème.
- `flutter test` : **91/91 verts** (dont `test/detection_ecart_test.dart` :
  6 tests de seuils + 3 scénarios session).
- `flutter build apk --debug` : OK (`app-debug.apk`). Réseau Gradle
   capricieux (TLS vers dl.google.com) : une ou deux relances suffisent.

### Bugs corrigés pendant la séance
- `SyncCloudIcon` : `_rotation` (`late final`) n'était lu que si une
  synchro tournait → créé **pendant** `dispose()`, plantage
  « Looking up a deactivated widget's ancestor is unsafe » qui faisait
  échouer `responsive_test`. Fix : forcer la création dans `initState`.
- pub : audioplayers ≥ 6.8 impose Flutter ≥ 3.44, vibration ≥ 3.2 impose
  Dart ≥ 3.11 → bornes abaissées (6.7.1 / 3.1.8) pour le SDK du poste.

### À FAIRE — prochaine séance
1. Valider sur tablette Android réelle : bip + vibration répétés toutes les
   ~5 s (filtre 5 m) hors parcours, bandeau qui disparaît au retour.
2. Côté serveur : produire `parcours` à chaque passe (l'affectation remplace
   toute la table) et geofences pour `alerte`.
3. Bouton « couper l'alerte manuellement » si besoin terrain (pas tranché).
4. Supervision §21 : afficher l'historique des alertes (journal existe déjà).

## S�ance du 2026-10-08 (suite 2) � Verrou par paire (blast, bloc) + fin des donn�es de d�mo

### Constats de d�part

- Le spotter affichait des **blasts de d�mo sem�s dans SQLite** (119/120/121
  avec lignes pr�-remplies) : aucune tablette de production ne doit d�marrer
  avec ce terrain invent�.
- Le verrou portait sur le **blast entier** (`blasts.verrouille`) : verrouiller
  le bloc 8 fermait aussi le bloc 6, alors que le terrain valide bloc par bloc.
- Un seul mode d'envoi (snapshot complet du blast) alors que l'exploitation
  veut choisir : blast entier, bloc courant ou seuls blocs verrouill�s.

### R�alisations

1. **Mod�le (`lib/models/models.dart`)**
   - `BlocTravail.verrouille` : �tat mutable par bloc.
   - `Blast.verrouille` devient un **getter d�riv�** (tous ses blocs
     verrouill�s) : les affichages � - verrouille � gardent leur sens.
2. **Sch�ma v6 (`lib/data/base_locale.dart`)**
   - `versionModele = 6`, `vers_modele = '6.0'` ; `blocs.verrouille INTEGER
     NOT NULL DEFAULT 0` (migration `de < 6` avec garde `PRAGMA table_info`).
   - `blasts.verrouille` n'est plus cr��e sur les nouveaux fichiers, plus
     lue ni �crite ; la colonne reste sans usage sur les anciens fichiers
     (`DROP COLUMN` non portable avant SQLite 3.35).
3. **Verrou par paire**
   - `verrouiller(BlocTravail)` / `deverrouiller(BlocTravail)` : �crivent
     `blocs.verrouille`, �mettent `BLAST_LOCK {blast, bloc, lignes}` /
     `BLAST_UNLOCK {blast, bloc}` ; d�verrouillage remet `blast.envoye = false`.
   - `ajouterLigne` refuse **seulement si le bloc cible est verrouill�** :
     changer de bloc fait � sauter � le verrou, c'est voulu.
4. **Trois modes d'envoi (`meta.envoi_mode`, PARAMETRES.md �3)**
   - `blast` (d�faut) : tous les blocs verrouill�s, snapshot complet.
   - `bloc` : bloc courant verrouill�, payload `BLAST_SEND` + champ `bloc`.
   - `verrouilles` : = 1 bloc verrouill�, snapshot des seuls blocs ferm�s.
   - Champ `mode` ajout� au payload `BLAST_SEND` ; `blast.envoye` reste par
     blast et retombe � faux d�s qu'un bloc est rouvert.
5. **Fin des donn�es de d�mo**
   - `BaseLocale({List<Blast>? blasts})` : production = **aucun blast** au
     premier lancement (les blasts viennent du serveur).
   - L'ancienne liste 119/120/121 devient `@visibleForTesting
     BaseLocale.blastsDemo()`, inject�e par les tests et par l'�cran de
     r�ponse du serveur.
   - `Session` : base injectable, s�lection par d�faut = premier blast re�u
     (vide tant que le serveur n'a rien envoy�), `verrouillerBloc` /
     `deverrouillerBloc`, `envoiMode` expos�.
6. **UI spotter (`lib/screens/spotter_screen.dart`)**
   - Cadenas = bloc courant ; dialogues � Verrouiller le bloc N du blast X ? �
     (compte les lignes du bloc).
   - Bouton Envoyer : `pret` selon le mode ; la fen�tre de confirmation
     annonce le p�rim�tre exact.
   - S�lection vide : � Aucun blast - en attente du serveur �.
7. **Contrat & docs**
   - `CDC SERVEUR.md` �3.2 : payloads `BLAST_LOCK`/`BLAST_UNLOCK` portent le
     `bloc` ; `BLAST_SEND` documente les 3 modes + champ `mode`.
   - `docs/API_SYNCHRO.md` : snapshot d�crit par p�rim�tre.
   - `PARAMETRES.md` : �3 `envoi_mode`, `vers_modele` 6.0.

### �tat v�rification
- `flutter analyze` : 0 problè.
- `flutter test` : **98/98 verts** (restructuration de `base_locale_test`
  autour de `blastsDemo()` + tests paire / 3 modes / sans dè / migration v6 ;
  `synchronisation_test` et `responsive_test` injectent la dè). Assertion
  corrigéé en fin de sé : `Blast.verrouille` (getter déé$) reste faux
  tant qu'un seul des deux blocs du blast 121 est verrouilléem le test ne
  vé donc que le bloc verrouillé$ et l'autre ouvert.
- `flutter build apk --debug` : OK
  (`build\app\outputs\flutter-apk\app-debug.apk`).

### Fin de sé— reprise demain
Point de reprise : la liste «— A FAIRE» ci-dessous.
### D�cisions retenues
- Verrou par **paire (blast, bloc)** : c'est le bloc qu'on valide au terrain,
  pas le blast entier ; le blast n'est � verrouill� � que si tous ses blocs
  le sont (getter d�riv�, utile au mode d'envoi `blast`).
- Statut � Envoy� � **par blast** (voulu exploitant) : un seul badge, il
  retombe d�s qu'un bloc redevient modifiable.
- `envoi_mode` lus dans `meta` � chaque envoi : les trois modes coexistent,
  le choix se fera dans l'�cran Param�tres (� venir) ou en SQL.

### � FAIRE � prochaine s�ance
1. �cran Param�tres : `envoi_mode` + `api_base`/`api_token` + seuils GPS.
2. R�ception serveur des nouveaux payloads (`BLAST_LOCK.bloc`,
   `BLAST_SEND.mode`/`bloc`) c�t� back-end.
3. Balisage � - verrouille � des blocs dans le s�lecteur de blocs (badge
   visuel par ligne du SimpleDialog).


---

## Séance du 2026-10-08 (après-midi) — UI, animations, démo offroad

### Réalisations
1. **Animations réseau réelles** (requêtes utilisateur) :
   - `Session.envoiWifiActif` / `envoiBleActif` / `synchroActive` : états
     d'animation pilotés par les événements réels (pas de simulation).
   - `_retransmettreFileWifi()` / `_retransmettreFileBle()` : dès que le lien
     devient vert, la file PENDING part automatiquement vers le DT.
   - `WifiClient.surReconnexion` : retransmission au retour du lien (REQ-008).
   - `DataExchangeButton` : flèche qui **tourne** pendant un envoi
     (Wi-Fi ou BLE), statique sinon. Ouvre la supervision réseau.
   - `SyncIconCloud` : nuage **animé** pendant une synchro serveur (4G),
     statique sinon (cloud_done vert / cloud_off).
2. **Réorganisation des voyants (barre haute)** :
   - Convention retenue : **voyant bluetooth = BLE**, **voyant wifi =
     connexion par hotspot**, nouveau **voyant GPS = récepteur USB-C**.
   - Écran DT : 4G à gauche, **nom centré**, à droite BLE + Wi-Fi hotspot +
     GPS. Écran excavatrice : 4G à gauche, nom + Synchro #n centrés,
     à droite BLE + GPS.
   - Nouveau `GpsStatusBadge` (icône `gps_fixed`) + `Session.etatGps`
     (rouge = service arrêté, orange = acquisition, vert = position reçue).
3. **Barre du bas épurée** :
   - Suppression des badges BLE/LAN compacts (`_BadgesCouche` /
     `_BadgeCoucheCompact` retirés du shell).
   - Il reste : **flèche à gauche** (animée pendant un envoi), **zone
     d'alerte au centre**, **nuage à droite** (animé pendant une synchro).
4. **Zone d'alerte (ticker)** : plus aucun message simulé.
   - `_seedNotifications()` réduit à un message neutre
     (« En attente de connexion »).
   - `_syncTick()` : plus de `nextInt` sur easting/northing/elevation, plus
     de message « Synchro #n terminée » factice. `_rng` et `_tick` supprimés.
   - `NotificationTicker` à deux régimes : **alerte active** → bandeau rouge
     plein cadre sans défilement ; sinon défilement des événements réels.
5. **Mode DÉMO OFFROAD (présentation)** :
   - `presentation/` créé à la racine (dossier de travail).
   - `GpsDemoOffroad` (`service_position.dart`) : fournisseur factice qui
     rejoue en boucle un scénario réaliste (sur le parcours → détour
     progressif > 40 m → retour). La session ne sait pas qu'elle est en
     démo : détection d'écart, bip, vibration fonctionnent comme en prod.
   - `Session.ouvrirBase(demoOffroad:)` : injecte le parcours fictif +
     affectation (destination F5M, RomPad 1) puis branche le GPS simulé.
   - `SplashScreen` : **5 taps rapides sur le logo** activent le mode démo ;
     un texte « MODE DEMO OFFROAD » apparaît sous le logo en confirmation.
   - `Clignotant` (`status_badges.dart`) : quand `alerteActive`, les
     voyants 4G/BLE/Wi-Fi/GPS et le bandeau rouge **clignotent**
     (opacité 1 → 0.25, période 600 ms). Hors alerte, aucun coût d'animation.
6. **Présentation PowerPoint** :
   - `presentation_ore_tracking.pptx` (6 diapos, 5 min) généré par
     `tool/generer_presentation.py` (python-pptx installé).
   - Points `routeProgress` documentés pour l'autre agent (valeur 0.62 en
     dur, +0.03 artificiel, GPS réel non branché — à corriger de son côté).

### État vérification
- `flutter analyze` : 0 problème (dernier passage avant l'APK).
- `flutter build apk --release` : **lancé mais interrompu** (timeout 120 s
  dans le terminal) — **à relancer en premier demain**.

### À FAIRE — prochaine séance
1. **Relancer `flutter build apk --release`** (mode démo inclus) et livrer
   l'APK dans `presentation/` avec les instructions d'installation
   (autorisation « sources inconnues » sur le téléphone).
2. ~~Écran Paramètres : `envoi_mode` + `api_base`/`api_token` + seuils GPS.~~
3. ~~Balisage « - verrouillé » des blocs dans le sélecteur (badge visuel).~~
4. Vérifier `routeProgress` après l'intervention de l'autre agent.

---

## Séance du 2026-10-09 — Écran Paramètres + badge de verrouillage

### Constat de départ
- Les **98 tests unitaires annoncés hier ont disparu** de `test/` (seul reste
  `test/diag_ecrans_test.dart`). Décision utilisateur : **poursuivre sans eux**
  (« c'est voulu ») — la couverture repose donc sur le diagnostic d'écrans.
- `dt_screen.dart` a été modifié entre-temps (12:45) : l'overflow
  `RenderFlex 6.4 px` signalé à 360×640 n'apparaît plus.

### Réalisations
1. **Badge « verrouillé » par bloc** (`spotter_screen.dart`, `_BlocOption`) :
   cadenas `Icons.lock` + suffixe « - verrouille » sur la ligne du bloc
   fermé, dans le `SimpleDialog` « Select bloc ». Chaque bloc porte désormais
   son état (paire blast/bloc) avant même d'être sélectionné.
2. **Écran Paramètres** (nouveau `lib/screens/parametres_screen.dart`,
   bouton « Paramètres » en haut de l'écran de connexion) :
   - Serveur : `api_base` (slash final retiré à l'enregistrement),
     `api_token` ;
   - Envoi : choix `envoi_mode` (`blast` / `bloc` / `verrouilles`) via
     `RadioGroup<String>` (API Flutter 3.35, `groupValue` déprécié) ;
   - Détection d'écart : `seuil_entree_m` (10–500), `seuil_sortie_m`
     (5 ≤ s < entree), `delai_confirmation_s` (0–300) ;
   - GPS : `intervalle_gps_s` (1–300), `filtre_distance_gps_m` (0–100).
   - Validation **avant toute écriture** (`meta` ne voit jamais un couple de
     seuils impossible) ; message d'erreur en rouge dans la page.
3. **Application en direct** :
   - `DetecteurEcart` : seuils non plus `final` + `configurer()` (refuse
     `sortie >= entree`, conserve le parcours, remet le compteur de
     confirmation à zéro) ;
   - `Session.rechargerParametres()` : relit les 5 clés, applique les seuils,
     **redémarre le GPS** (`_redemarrerGps`) si la cadence/filtre a bougé ;
     appelé à l'ouverture de la base et à chaque enregistrement ;
   - `GpsReel` / `ServicePosition` : `filtreDistance` paramétrable
     (était codé en dur à 5 m).
4. **Diagnostic d'écrans élargi** : `login` et `parametres` ajoutés aux 5
   tailles × 3 (8 tailles au total) — **40 tests, 0 erreur de rendu**.

### Documentation
- `PARAMETRES.md` : §intro (écran réel), §3 (choix UI), §4 (seuils actifs),
  §5 (clés GPS actives + bornes), §7 (procédure mise à jour).

### État vérification
- `flutter analyze` : **0 problème**.
- `flutter test` : **40/40 verts** (diagnostic d'écrans, 5 pages × 8 tailles).
- `flutter build apk` : **non lancé** (demande explicite : construction des
  pages uniquement cette séance). Gradle en cours arrêté.

### À FAIRE — prochaine séance
1. Construire l'APK (`flutter build apk --release`) quand demandé.
2. Réception serveur des payloads (`BLAST_LOCK.bloc`,
   `BLAST_SEND.mode`/`bloc`) côté back-end — **aucun code serveur dans ce
   dépôt** (seul `CDC SERVEUR.md` le spécifie) : à traiter là où vit le
   back-end.
3. Vérifier `routeProgress` après l'intervention de l'autre agent.

---

## Séance du 2026-10-09 (après-midi) — APK release + mise en ligne Git

### Réalisations
1. **APK release construit** : `flutter build apk --release` →
   `build\app\outputs\flutter-apk\app-release.apk` (18,5 Mo, code retour 0,
   384 s Gradle). ⚠️ **pas encore copié dans `presentation/`** (étape 2 de
   `REPRISE-DEMAIN.md`).
2. **Dépôt Git créé et publié** — le projet n'était pas versionné :
   - `git init` (branche `main`), identité **locale uniquement**
     `ivandjeapro-gif <ivandjeapro@gmail.com>` ;
   - `origin = https://github.com/ivandjeapro-gif/OT2-Tab.git` ;
   - commit initial `75eeb22` : **126 fichiers / 4,3 Mo** (le `.gitignore`
     standard Flutter écarte `build/`, `.dart_tool/`, `*.log`, `*.apk`) ;
   - `main` tracke `origin/main`.
3. **`flutter_screenutil: ^5.9.3` ajouté au `pubspec.yaml`** (+ `pub get`) —
   **aucun usage dans `lib/`** : à confirmer (l'utiliser ou le retirer).
4. Les 2 dépréciations `RadioGroup` d'`analyze.log` sont corrigées :
   `flutter analyze` = **0 problème**.

### En cours — interrompu, repris demain
- `_TopBar` (`lib/screens/dt_screen.dart:290`) : positionnement du groupe de
  badges de droite (BLE / Wi-Fi / GPS) dans son `Flexible(flex:3)`. Le
  comportement de `FittedBox(scaleDown)` + `RenderFlex` a été étudié dans le
  SDK (un enfant `Flexible` plus étroit que son allocation ne consomme pas sa
  place : `RenderFlex` la comptabilise comme espace libre, donc les badges se
  calent après le nom et non contre le bord droit). **Aucune modification
  appliquée.**

### État vérification
- `flutter analyze` : **0 problème**.
- `flutter test` : 24/24 (diagnostic d'écrans, 8 tailles × 3 pages).
- `flutter build apk --release` : **OK** (voir ci-dessus).

### À FAIRE — prochaine séance
1. Copier `app-release.apk` dans `presentation/` et vérifier `INSTALLER.md`.
2. Trancher sur `flutter_screenutil` (responsive via le plugin, ou retrait du
   `pubspec`).
3. Suite du `_TopBar` (groupe de badges à caler à droite) si besoin terrain.
4. Inchangés : réception serveur des payloads `BLAST_LOCK.bloc` /
   `BLAST_SEND.mode`/`bloc`, vérification de `routeProgress`, validation BLE
   sur deux tablettes Android réelles.
