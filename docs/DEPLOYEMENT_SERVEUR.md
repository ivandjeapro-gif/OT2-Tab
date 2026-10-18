# Déploiement du serveur `server_OT` (Google Apps Script)

Guide de mise en service du serveur central ORE TRACKING sur Google Apps
Script. Le code du serveur est le fichier `server_OT` à la racine du projet —
son contenu entier se copie-colle dans l'éditeur Apps Script.

---

## 1. Créer le Spreadsheet (la « base de données »)

Créer simplement un **Google Spreadsheet vide** — le serveur crée lui-même ses
7 onglets (`server_OT` les initie automatiquement à chaque requête, et la
fonction `initialiserOnglets` est exécutable à la main depuis l'éditeur Apps
Script : Run ▶ `initialiserOnglets`).

Onglets créés automatiquement, avec leurs en-têtes :

| Onglet | Rôle | Colonnes |
|---|---|---|
| `evenements` | File d'entrée des tablettes | A: `event_id`, B: `gateway_id`, C: `source_device`, D: `event_type`, E: `timestamp`, F: `received_at`, G: `payload`, H: `easting`, I: `northing` |
| `affectation` | Mission en cours (clé/valeur) | A: `cle`, B: `valeur` — lignes utiles : `destination`, `dumping_area`, `mission`, `alerte`, `parcours`, `valide_le` |
| `blasts` | Liste des blasts servie au spotter | A: `numero`, B: `carte` (l'entête en ligne 1 est requise) |
| `blocs` | Blocs de chaque blast | A: `blast`, B: `numero` |
| `cartes` | Libellés des cartes | A: `code`, B: `libelle` |
| `positions` | Points connus (départ, dumping areas) | A: `code`, B: `lat`, C: `lng` — mettre `DEPOT` pour le point de départ du parcours |
| `notifications` | Canal Boss → tablette | A: `id`, B: `profil`, C: `message`, D: `horodatage` — l'`id` est généré par le serveur à l'écriture, il sert de curseur de reprise au client |
| `journal` | Trace horodatée (audit §3.4) | A: `horodatage`, B: `message` (rempli automatiquement) |

L'onglet `evenements` est créé **sans en-tête** (chaque ligne est un
événement) ; les six autres reçoivent leur ligne d'en-tête en gras, gelée.
Les onglets déjà existants ne sont jamais touchés : l'initialisation ne
comble que les absents.

### 1b. Le canal notifications (Boss au bureau → spotter sur le terrain)

Le Boss dépose un message pour une tablette de deux façons :

**a) Écrire directement dans l'onglet** `notifications` (à la main dans le
Spreadsheet) : remplir `profil` (`spotter`, `dt`, `excavator`, ou vide =
tous) et `message` ; l'`id` sera complété à la prochaine écriture serveur.

**b) Par HTTP** (pour un outil de supervision ou un script) :

```
POST {api_base}?action=notification&token=<JETON>
Content-Type: application/json

{ "profil": "spotter", "message": "Va au blast 122, il y a urgence" }
```

Réponse : `{"ok": true, "id": 3, ...}` — l'id est généré par le serveur.

**Lecture par la tablette** : à chaque passe de synchro (toutes les 5 s quand
la 4G est là), le client appelle `GET ?action=notifications&depuis=<dernier
id connu>`. Le serveur rend tout ce qui est plus récent ; le client stocke
les messages en base locale (ils survivent au redémarrage) et affiche chacun
dans sa zone de messages préfixé `BOSS - `. `profil` vide = message pour
tous ; ciblé, il ne sort que pour le profil nommé. Une coupure de réseau ne
perd rien : le curseur `derniere_id_notif` vit en base et la reprise ne
rejoue que ce qui manque réellement.

Exemple de contenu de départ pour `affectation` :

```
cle            valeur
destination    F5M
dumping_area   RomPad 1
mission        A-2026-10-08
alerte
```

Exemple pour `blasts` / `blocs` / `cartes` :

```
blasts (ligne 1 = entête)          blocs (ligne 1 = entête)      cartes
numero | carte                     blast | numero                code | libelle
119    | A1                        119   | 6                     A1   | Fosse A - niveau 1
120    | B2                        119   | 7                     B2   | Fosse B - niveau 2
                                   120   | 1
```

## 2. Préparer le Drive

1. Créer un **dossier** « Plans ORE » contenant les plans JPG nommés
   `plan_<carte>.jpg` (ex. `plan_A1.jpg`, `plan_B2.jpg`).
2. Importer (si disponible) le fichier **`Trails.geojson`** des pistes du site
   (`LineString` en UTM mètres — même source que le poste de supervision).

Relever les **ID** du Spreadsheet, du dossier de plans et du fichier GeoJSON
(dans leurs URLs).

## 3. Coller le code

1. Dans le Spreadsheet : **Extensions → Apps Script**.
2. Supprimer le code par défaut, coller la totalité du fichier **`server_OT`**.
3. Renseigner `CONFIG` en tête de fichier :

```js
SPREADSHEET_ID:    '<ID du Spreadsheet>',
TOKEN:             '<jeton long et aléatoire, ex. openssl rand -hex 32>',
DOSSIER_PLANS_ID:  '<ID du dossier de plans>',
FICHIER_PISTES_ID: '<ID du Trails.geojson>',
```

4. **Enregistrer**.

## 4. Déployer la Web App

1. **Déployer → Nouveau déploiement → Application Web**.
2. Réglages **obligatoires** :
   - *Execute as* : **Me** (c'est le serveur qui lit/écrit le Spreadsheet) ;
   - *Who has access* : **Anyone** (l'auth est faite par le jeton `?token=`).
3. Déployer et **copier l'URL** : elle finit par `/exec`.
4. Autoriser les scopes demandés (Sheets, Drive, Script Properties).

> À chaque modification du code : **Déployer → Gérer les déploiements → ✏️
> Modifier → Version : Nouvelle version → Déployer** (sinon l'ancien code
> continue de répondre).

## 5. Vérifier le déploiement

Ouvrir dans un navigateur :

```
https://script.google.com/macros/s/<DEPLOYMENT_ID>/exec?action=sante&token=<JETON>
```

Réponse attendue :

```json
{
  "ok": true,
  "service": "ORE TRACKING serveur",
  "protocole": "1.0",
  "onglets": { "evenements": 0, "affectation": 5, ... },
  "pistes": "ok",
  "plans": "ok"
}
```

Si un onglet ou une ressource Drive répond `MANQUANT`/`INACCESSIBLE`, corriger
la configuration avant de brancher une tablette.

## 6. Régler les tablettes

Dans l'application, écran **Paramètres** :

| Clé `meta` | Valeur |
|---|---|
| `api_base` | l'URL de la Web App (celle qui finit par `/exec`) |
| `api_token` | le `TOKEN` du `CONFIG` |

Le client détecte automatiquement le régime Apps Script (URL finissant par
`/exec` ou `/dev`) et bascule sur :

- `POST ?action=evenement&token=...` (corps = enveloppe CDC §12, inchangée) ;
- `GET ?action=affectation`, `GET ?action=blasts`, `GET ?action=plan&carte=...`.

Aucune autre configuration n'est nécessaire ; `envoi_mode` et les seuils GPS
restent gérés comme avant.

## 7. Checklist de mise en service (adaptée du CDC §7)

- [ ] `?action=sante` répond `ok:true` avec tous les onglets `>= 0`.
- [ ] POST d'un événement (via l'app : ajouter une ligne, puis `Envoyer`)
      → l'onglet `evenements` gagne une ligne, la notification app affiche
      « Synchro serveur - N evenement(s) valide(s) ».
- [ ] Rejeu du même `event_id` (couper le réseau juste après un POST, puis
      retenter) → réponse `status: DOUBLON`, **pas de seconde ligne**.
- [ ] Mauvais jeton (changer `api_token` dans l'app) → notification
      « Serveur injoignable » et les événements restent en file PENDING.
- [ ] `?action=affectation` renvoie la mission avec `parcours` — la tablette
      affiche la destination et le trajet se dessine.
- [ ] `?action=blasts` renvoie la liste — les menus « Select blast / bloc » de
      l'écran spotter se remplissent et les plans se téléchargent
      (notification « Plan telecharge »).
- [ ] Coupure 4G pendant une saisie → rien ne se perd, la file se vide seule
      au retour (comportement client, inchangé).

## 8. Limites connues (documentées, voir analyse §6/10)

- **Statuts HTTP aplatis** : tout sort en 200, la sémantique 202/409/4xx
  voyage dans `{"ok": ..., "ack": ...}` — le client lit le corps.
- **En-têtes invisibles** : jeton en query param (HTTPS obligatoire, respecté
  par le déploiement Web App).
- **Écriture Sheets séquentielle** (~2 lignes/s) : dimensionné pour 3
  tablettes ; au-delà, migrer vers un vrai backend (l'architecture injectable
  du client ne change pas).
- **Dijkstra** : caché 60 s par mission ; recalcul à la demande si la
  destination change, sinon le dernier parcours valide est conservé.
- **Réponse du plan** : binaire JPEG (seule réponse non-JSON du serveur).

## 9. Sécurité

- Le jeton est le seul secret : **ne jamais** le partager hors des tablettes ;
  le révoquer = changer `CONFIG.TOKEN` + `meta.api_token` côté app.
- HTTPS est garanti par Google (Web App) — le jeton ne transite jamais en clair.
- La Web App « Anyone » ne donne accès qu'aux 4 actions routées et authentifiées ;
  aucun scope d'écriture Drive n'est exposé (les plans sont lus en binaire).
