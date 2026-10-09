# API de synchronisation ORE TRACKING

Contrat entre la passerelle (TAB 2, §3) et le serveur central (§14).
Version du protocole : **1.0** (`meta.vers_protocole`), modèle de données **5.0**
(`meta.vers_modele`).

## 1. Endpoint

```
POST {api_base}/evenements
```

`api_base` et `api_token` sont lus dans la table `meta` (aucune URL codée en dur
dans l'application).

| En-tête | Valeur |
| --- | --- |
| `Content-Type` | `application/json; charset=utf-8` |
| `Authorization` | `Bearer {api_token}` (§18.3) |
| `X-Gateway-Id` | `gateway_id` de la passerelle (REQ-017) |
| `X-Protocol-Version` | `1.0` (§23) |

## 2. Corps — enveloppe d'événement (§12)

```json
{
  "event_id": "3f1a9d64-0d0e-4d4b-9c6b-1f6c1a2b3c4d",
  "gateway_id": "TAB-002",
  "source_device": "TAB3-004",
  "event_type": "LINE_ADD",
  "timestamp": "2026-10-07T11:32:18.000Z",
  "payload": {
    "blast": "119",
    "bloc": "7",
    "time": "07h35",
    "dt": "1500",
    "id_dt": "06",
    "has_picture": true,
    "photo": "/9j/4AAQSkZJRgABAQAAAQ...",
    "comment": ""
  }
}
```

Le `payload` d'un `LINE_ADD` reprend **tous** les champs saisis dans le
formulaire de chargement — rien ne reste sur le poste :

| Champ | Type | Origine |
| --- | --- | --- |
| `blast`, `bloc` | string | blast/bloc courant au moment de la saisie |
| `time` | string (`HHhMM`) | heure de saisie (§9) |
| `dt`, `id_dt` | string | famille et numéro de DT choisis |
| `has_picture` | bool | la ligne a-t-elle une photo |
| `photo` | string **base64** | octets JPEG de la photo (`lignes.photo`), présent seulement si la ligne en a une |
| `comment` | string | commentaire libre |

Le `payload` d'un `BLAST_SEND` (bouton « Envoyer ») est un **snapshot du
périmètre** choisi par le réglage `envoi_mode` (`blast` par défaut, `bloc` ou
`verrouilles` — voir `PARAMETRES.md` §3) : les compteurs, plus `donnees`, la
liste des lignes de ce périmètre. Les lignes créées au démarrage, qui n'ont
jamais eu de `LINE_ADD`, partent donc ici — aucune donnée ne reste sur le
poste. Le champ `mode` dit quel périmètre a été envoyé ; `bloc` précise le
bloc quand `mode = "bloc"`.

```json
{
  "blast": "119",
  "carte": "A1",
  "mode": "blast",
  "lignes": 7,
  "blocs": 3,
  "donnees": [
    {
      "bloc": "7",
      "time": "07h40",
      "dt": "1500",
      "id_dt": "01",
      "has_picture": true,
      "photo": "/9j/4AAQSkZJRgABAQAAAQ...",
      "comment": "Charge blast"
    }
  ]
}
```

Le reste de l'enveloppe :

| Champ | Type | Origine |
| --- | --- | --- |
| `event_id` | UUID v4 | colonne `evenements.event_id` (REQ-014) |
| `gateway_id` | string | colonne `evenements.gateway_id` (passerelle qui relaie) |
| `source_device` | string | colonne `evenements.source_device` (émetteur) |
| `event_type` | string | `LINE_ADD`, `BLAST_LOCK`, `BLAST_UNLOCK`, `BLAST_SEND`, … |
| `timestamp` | ISO 8601 UTC | colonne `evenements.timestamp` |
| `payload` | objet | colonne `evenements.payload` (JSON décodé) |

`rssi` n'est pas transmis : colonne réservée à la couche radio (décision C3).

## 3. Réponses

| Code | Signification | Traitement côté client (§14) |
| --- | --- | --- |
| `202 Accepted` | ACK : `{ "ack": { "event_id": "...", "status": "SYNCED", "received_at": "..." } }` | `marquerSynchronise` → état `SYNCED` |
| `409 Conflict` | Événement déjà reçu (REQ-015) | **idempotent** : traité comme un ACK → `SYNCED` |
| `400 / 422` | Enveloppe invalide | retour `PENDING`, nouvelle tentative (l'événement reste en file) |
| `401 / 403` | Authentification refusée | retour `PENDING`, message à l'opérateur, le backoff s'applique |
| `5xx` | Erreur serveur | retour `PENDING` + backoff |
| réseau / timeout | Serveur injoignable | retour `PENDING` + backoff (REQ-013) |

Aucune réponse n'est jamais interprétée comme une perte : l'événement ne quitte
la file `PENDING` que par un ACK explicite (REQ-012).

## 4. Idempotence (REQ-015)

Le serveur utilise `event_id` comme clé d'unicité : renvoyer deux fois le même
événement (reprise après coupure) ne doit créer qu'un enregistrement. La réponse
`409` signale ce cas et doit être considérée comme un succès par le client.

## 5. Politique de rejeu (§14, §15)

```
PENDING → SENDING → ACK → SYNCED
    ↑          │
    └──────────┘  échec : retour PENDING, prochaine_tentative = now + min(5 s × 2^n, 15 min)
```

- `n` = nombre de tentatives (`evenements.tentatives`), incrémenté à chaque
  envoi.
- Tant que `gsmOnline == false`, aucune tentative n'est faite : les événements
  restent en `PENDING` (§15, REQ-012).
- À l'ouverture de la base, les événements restés `SENDING` (arrêt brutal) sont
  repassés en `PENDING` (§24).
- Parcours : 20 événements par passe, dans l'ordre `rowid` (ordre de création).

## 6. Extension (non implémentée)

```
POST {api_base}/evenements/batch   { "events": [ enveloppe, … ] }
```

Réponse : un tableau d'ACK par `event_id`. La version 1.0 envoie un événement à
la fois ; le batch est prévu pour les volumétries terrain.

## 7. Configurations (`meta`)

| Clé | Défaut | Rôle |
| --- | --- | --- |
| `api_base` | — | racine de l'API (sans `/evenements`) |
| `api_token` | — | jeton d'authentification TAB 2 (§18.3) |
| `vers_protocole` | `1.0` | envoyée dans `X-Protocol-Version` |

## 8. Affectation (destination / dumping area)

La destination et la dumping area d'un trajet sont **choisies puis validées
par le serveur** : l'application ne les saisit jamais, elle les affiche et
les conserve. Endpoint dédié, distinct du POST — la lecture ne dépend donc
pas de la file d'événements, qui peut être vide pendant de longues minutes.

```
GET {api_base}/affectation
```

| En-tête | Valeur |
| --- | --- |
| `Authorization` | `Bearer {api_token}` |
| `X-Protocol-Version` | `1.0` |

**Réponse `200 OK`**

```json
{
  "affectation": {
    "destination": "F5M",
    "dumping_area": "RomPad 1",
    "mission": "A-2026-10-08",
    "parcours": "[[320100,920400],[320450,920510],[320980,920640]]",
    "alerte": ""
  },
  "valide_le": "2026-10-08T09:00:00Z"
}
```

| Champ | Rôle |
| --- | --- |
| `affectation` | objet de paires `clé → valeur` (`destination`, `dumping_area`, `mission`, …) |
| `valide_le` | instant où le serveur a validé cette affectation (ISO 8601 UTC), affiché en badge |

**Clés particulières lues par la tablette**

| Clé | Format | Rôle |
| --- | --- | --- |
| `parcours` | JSON `[[easting, northing], …]` (UTM mètres, **≥ 2 points**) | trajet prévu vers la dumping area ; la tablette mesure l'écart de sa GPS à cette polyline (détection locale : sortie > **40 m** pendant **15 s**, retour < **20 m**) |
| `alerte` | texte libre, vide = rien | repli « option A » : message du serveur affiché tel quel quand aucun `parcours` n'est reçu (geofences côte serveur) |

Comportement de la détection :
- `parcours` absent, vide ou malformé : détection locale inactive, la
  tablette se rabat sur `alerte` (aucune erreur, aucune écriture parasite) ;
- une affectation sans `parcours` **remplace toute la table** (contrat §8) :
  si le trajet doit survivre, le serveur renvoie `parcours` à chaque passe ;
- pendant l'alerte, chaque mesure GPS rejoue un bip + une vibration ;
- le bandeau rouge de l'écran DT affiche l'écart en mètres et disparaît au
  retour sur le trajet.

**Traitement côté client**

| Réponse | Traitement |
| --- | --- |
| `200` avec au moins un champ | remplacement **complet** de la table `affectation`, avec `valide_le` |
| `200` sans champ | aucune écriture |
| `404` | aucune affectation en cours — la dernière valeur connue est conservée |
| `401 / 403 / 4xx / 5xx` | aucune écriture, la dernière valeur est conservée |
| réseau / timeout | aucune écriture (REQ-012) : une erreur ne peut jamais effacer une destination |

Comportement :
- la table `affectation` n'a qu'une seule porte d'écriture,
  `BaseLocale.enregistrerAffectation` — aucun écran ne la modifie ;
- une réponse identique à celle déjà en base n'est pas réécrite (pas de
  journal inutile, pas d'écriture disque toutes les 5 s) ;
- le worker appelle cet endpoint **à chaque passe** (`Synchronisation.
  unePasseAffectation`), uniquement quand `reseauDisponible == true` ;
- un contenu inchangé entre deux passes n'est pas notifié.
