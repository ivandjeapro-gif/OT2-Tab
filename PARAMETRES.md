# Paramètres ORE TRACKING — tablette

Référence de **tous les réglages** du projet : clés de la table `meta`, valeurs
par défaut, bornes, effet de chacun, et où elles sont lues dans le code.

- Écriture : `BaseLocale.majMeta(cle, valeur)` → `INSERT OR REPLACE INTO meta`.
- Lecture : `base.meta(cle)` ; **clé absente = valeur par défaut** (aucune
  migration nécessaire pour ajouter un réglage).
- **Écran « Paramètres »** (`lib/screens/parametres_screen.dart`, bouton en
  haut de l'écran de connexion) : saisit `api_base`, `api_token`, `envoi_mode`,
  les seuils de détection d'écart et le GPS. Les seuils sont réappliqués par
  `Session.rechargerParametres()` au moment de l'enregistrement ; `api_*` et
  `envoi_mode` sont relus à chaque envoi. Les clés restantes (versions,
  protocole) restent en SQL.

---

## 1. Serveur (synchro §14, contrat `docs/API_SYNCHRO.md`)

| Clé | Défaut | Effet | Lu par |
| --- | --- | --- | --- |
| `api_base` | — | Racine de l'API serveur, **sans slash final** (ex. `https://central.example/api`). Absente → aucun POST n'est tenté (erreur « api_base absente »). | `TransmetteurHttp` (envoi + lecture affectation) |
| `api_token` | — | Jeton d'authentification, envoyé en `Authorization: Bearer …` (§18.3). | `TransmetteurHttp` |
| `vers_protocole` | `1.0` | En-tête `X-Protocol-Version` envoyé au serveur. | `TransmetteurHttp` |

> `api_base` et `api_token` sont relus **à chaque envoi** : les changer ne
> demande aucun redémarrage de l'application.

## 2. Versions (§23)

| Clé | Défaut | Effet |
| --- | --- | --- |
| `vers_app` | `1.0.0` | Version applicative visible (badges, journal). |
| `vers_protocole` | `1.0` | Version du contrat HTTP (voir §1). |
| `vers_modele` | `6.0` | Version du schéma SQLite local ; pilote les migrations `_versionner`. |

## 3. Envoi des données du spotter (`meta.envoi_mode`)

Choisit le **périmètre** du bouton « Envoyer » de l'écran spotter. Clé absente
= `blast` (comportement historique). Lue à chaque envoi, changement sans
redémarrage.

| Valeur | Effet | Condition de départ |
| --- | --- | --- |
| `blast` *(défaut)* | Snapshot **complet** du blast : toutes ses lignes, photos comprises. | Tous les blocs du blast doivent être verrouillés. |
| `bloc` | Snapshot du **seul bloc courant** (le payload `BLAST_SEND` porte le champ `bloc`). | Le bloc courant doit être verrouillé et non vide. |
| `verrouilles` | Snapshot des **seuls blocs verrouillés** du blast (les blocs encore ouverts ne partent pas). | Au moins un bloc verrouillé et non vide. |

Dans les trois cas, le statut « Envoyé » reste porté par le **blast** ; il est
remis à faux dès qu'un de ses blocs est déverrouillé (les données redeviennent
modifiables). Réglable depuis l'écran Paramètres (liste de choix) ou en SQL :

```sql
INSERT OR REPLACE INTO meta (cle, valeur) VALUES ('envoi_mode', 'bloc');
```

## 4. Détection d'écart hors-parcours (écran DT, options A + B)

Seuils portés par `DetecteurEcart`
(`lib/communication/position/detection_ecart.dart`) et **reconfigurables en
direct** : `DetecteurEcart.configurer()` puis `Session.rechargerParametres()`
à l'enregistrement de l'écran Paramètres. Un couple incohérent
(`seuil_sortie_m >= seuil_entree_m`) est refusé sans rien modifier.

| Clé prévue | Défaut | Bornes conseillées | Effet |
| --- | --- | --- | --- |
| `seuil_entree_m` | `40` | 10 – 500 | Distance au parcours au-delà de laquelle le DT est considéré **hors trajet** (doit être maintenue pendant `delai_confirmation_s`). |
| `seuil_sortie_m` | `20` | 5 – `seuil_entree` − 1 | Distance en dessous de laquelle le DT est de nouveau **sur le trajet** (retour immédiat). Entre les deux : hystérésis, l'état précédent est conservé. **Impose** `seuil_sortie_m < seuil_entree_m`. |
| `delai_confirmation_s` | `15` | 0 – 300 | Temps pendant lequel l'écart doit rester au-dessus du seuil d'entrée avant de déclencher (un bruit GPS isolé n'alerte pas). |

Rappel de comportement (contrat `docs/API_SYNCHRO.md` §8) :
- le parcours vient du serveur, champ `affectation.parcours`
  (`[[easting, northing], …]` UTM mètres) ;
- sans `parcours`, repli sur le champ `affectation.alerte` (geofences côté
  serveur) ;
- **chaque mesure GPS pendant l'alerte rejoue le bip + la vibration**.

## 5. GPS (§5)

Clés `meta` lues à l'ouverture de la base, puis à chaque enregistrement de
l'écran Paramètres (`Session.rechargerParametres`) : si la cadence ou le filtre
a bougé, le service de position est **redémarré** avec les nouvelles valeurs.

| Clé | Défaut | Bornes | Effet | Où |
| --- | --- | --- | --- | --- |
| `intervalle_gps_s` | `5` | 1 – 300 | Cadence du flux GPS avant mise en file (`GPS_UPDATE`). | `ServicePosition.intervalle` → `GpsReel.intervalle` |
| `filtre_distance_gps_m` | `5` | 0 – 100 | Aucune mesure n'est produite si le device n'a pas bougé de cette distance : les véhicules immobiles ne font pas gonfler la file ni rejouer l'alerte. | `ServicePosition.filtreDistance` → `GpsReel.filtreDistance` |

## 6. Constantes non réglables (codées en dur, à ne pas confondre avec `meta`)

| Constante | Valeur | Rôle | Fichier |
| --- | --- | --- | --- |
| Passe de synchro | 5 s | Cadence du worker serveur. | `synchronisation.dart` |
| Lots par passe | 20 | Événements maximum envoyés par itération. | `synchronisation.dart` |
| Backoff | `min(5 s × 2^n, 15 min)` | Retour en `PENDING` après échec (REQ-013). | `synchronisation.dart` |
| Timeout HTTP | 15 s | Annulation d'une requête bloquante (REQ-012). | `transmetteur.dart` |
| Port Wi-Fi P2P | 45210 | Port TCP du point d'accès TAB 2. | `session.dart` |
| Portée Wi-Fi | ~40 m | Portée annoncée du point d'accès (REQ-007/008). | CDC |
| Clients BLE max | 5 | Capacité du gateway TAB 2. | `ble_gateway.dart` |
| Seuils proximité | −70 / −80 dBm | Hystérésis d'entrée/sortie du contrôle de proximité. | `ble_protocole.dart` |
| Mesures de contact | 3 | Confirmations RSSI avant d'accepter un lien. | `ble_protocole.dart` |
| Notifications gardées | 12 | Taille du journal affiché (`Session.push`). | `session.dart` |
| En-tête alerte | rouge, écart en m | Bandeau `dt_screen` pendant l'alerte trajet. | `dt_screen.dart` |

## 7. Comment changer un réglage

1. **Écran Paramètres** (bouton « Paramètres » en haut de l'écran de
   connexion) : `api_base`, `api_token`, `envoi_mode`, les 3 seuils de
   détection et les 2 réglages GPS. Validation des bornes avant écriture ;
   les seuils et le GPS sont réappliqués sans redémarrage, le GPS est
   redémarré si sa cadence a changé.
2. Via le code : constante + défaut, puis mise à jour de ce fichier.
3. Via SQL (clé non couverte par l'écran, ex. `vers_protocole`) :
   `INSERT OR REPLACE INTO meta (cle, valeur) VALUES ('vers_protocole', '1.1');`
4. Aucun redémarrage n'est nécessaire pour `api_base`, `api_token` et
   `vers_protocole` : ils sont relus à chaque envoi.
