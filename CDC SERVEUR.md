# CDC SERVEUR — ORE TRACKING

Spécification **côté serveur central** : tout ce qu'il faut implémenter pour
recevoir les tablettes et leur renvoyer l'affectation de mission.

- Protocole HTTP : **1.0** · Modèle de données : **5.0**
- Contrat client détaillé (vu tablette) : `docs/API_SYNCHRO.md`
- Référence des réglages : `PARAMETRES.md`

---

## 1. Vue d'ensemble

```
TAB 1 (spotter) ──BLE/Wi-Fi──▶ TAB 2 (DT, passerelle) ──HTTPS 4G──▶ SERVEUR CENTRAL
TAB 3 (excavatrice) ──BLE────▶        ▲
                                      │ GET /affectation (destination, parcours, alerte)
```

- **TAB 2 est le seul client HTTPS** : il consomme sa file locale d'événements
  (`PENDING`) et l'envoie un par un ; les TAB 1/3 lui transmettent par BLE/Wi-Fi.
- Le serveur **pousse rien** : la tablette tire l'affectation par polling
  (une passe toutes les 5 s quand la 4G est là).
- Authentification : jeton partagé `api_token`, stocké côté tablette dans la
  table `meta` (voir `PARAMETRES.md` §1).

## 2. En-têtes communs

| En-tête | Valeur | Obligatoire |
| --- | --- | --- |
| `Content-Type` | `application/json; charset=utf-8` | POST uniquement |
| `Authorization` | `Bearer {api_token}` | oui |
| `X-Gateway-Id` | identifiant de la passerelle TAB 2 (ex. `TAB2-001`) | POST uniquement |
| `X-Protocol-Version` | `1.0` | oui |

Un `X-Protocol-Version` inconnu doit être refusé (400) plutôt que d'être ignoré.

## 3. POST /evenements — remontée des données

### 3.1 Enveloppe (CDC §12)

```json
{
  "event_id": "3f1a9d64-0d0e-4d4b-9c6b-1f6c1a2b3c4d",
  "gateway_id": "TAB2-001",
  "source_device": "TAB3-004",
  "event_type": "LINE_ADD",
  "timestamp": "2026-10-08T11:32:18.000Z",
  "payload": { }
}
```

| Champ | Type | Règle serveur |
| --- | --- | --- |
| `event_id` | UUID v4 | **Clé d'unicité** (idempotence REQ-015) : un doublon ne doit jamais créer un second enregistrement. |
| `gateway_id` | string | Passerelle qui relaie (TAB 2). À stocker pour l'audit. |
| `source_device` | string | Émetteur d'origine (TAB 1 ou TAB 3, ou TAB 2 lui-même). |
| `event_type` | string | Voir §3.2. |
| `timestamp` | ISO 8601 UTC | Horodatage de création côté tablette ; conserver tel quel. |
| `payload` | objet | Format dépendant de `event_type` (§3.2). |

### 3.2 Types d'événements et payloads

| `event_type` | Émetteur | Payload |
| --- | --- | --- |
| `GPS_UPDATE` | toute tablette équipée d'un GPS | `{"easting": 320453, "northing": 920443, "elevation": 260, "lat": 45.777, "lng": 3.087}` — `easting`/`northing` en **mètres UTM** (entiers), `lat`/`lng` présents seulement si le device les connaît. C'est cette file qui alimente le suivi de position et la décision d'affectation. |
| `LINE_ADD` | TAB 1 (spotter) | `{"blast":"119","bloc":"7","time":"07h35","dt":"1500","id_dt":"06","has_picture":true,"photo":"<base64 JPEG>","comment":""}` — photo **base64** (JPEG), présente seulement si la ligne en a une. |
| `BLAST_LOCK` | TAB 1 | `{"blast":"119","bloc":"7","lignes":3}` — le **bloc** est validé, plus rien ne peut y être ajouté. Le verrou porte sur la paire (blast, bloc) : les autres blocs du même blast restent ouverts tant qu'ils ne sont pas verrouillés tour à tour. |
| `BLAST_UNLOCK` | TAB 1 | `{"blast":"119","bloc":"7"}` — remise en saisie de ce bloc ; les données déjà transmises du blast deviennent potentiellement obsolètes (statut `envoye` remis à faux). |
| `BLAST_SEND` | TAB 1 | Snapshot du périmètre choisi par le réglage `envoi_mode` : **`blast`** (défaut) = toutes les lignes du blast, tous ses blocs verrouillés ; **`bloc`** = le seul bloc courant (champ `bloc` présent) ; **`verrouilles`** = les seuls blocs verrouillés. Exemple : `{"blast":"119","carte":"A1","mode":"blast","lignes":7,"blocs":3,"donnees":[{…toutes les lignes, photos comprend…}]}`. C'est la garantie « rien ne reste sur le poste ». |
| `BLE_RELAY` | TAB 2 | Événement reçu d'un TAB 3 par BLE, **relais** : le payload est l'enveloppe d'origine, à traiter comme telle (le serveur peut en extraire le `source_device` réel). |

### 3.3 Réponses

| Code | Corps | Signification |
| --- | --- | --- |
| `202 Accepted` | `{"ack":{"event_id":"…","status":"SYNCED","received_at":"…"}}` | Événement accepté et stocké. |
| `409 Conflict` | message libre | `event_id` déjà traité → **succès** pour le client (idempotent). |
| `400 / 422` | message libre | Enveloppe invalide → le client rejouera (l'événement reste en file). |
| `401 / 403` | message libre | Jeton absent/refusé ; le client applique son backoff. |
| `4xx` autre | message libre | Rejeté, rejouable. |
| `5xx` | message libre | Erreur serveur ; le client rejoue avec backoff. |

### 3.4 Règles serveur

- **Idempotence** : contrainte d'unicité sur `event_id` ; le `409` doit être
  renvoyé pour tout rejeu (coupure réseau, redémarrage).
- **Aucune perte** : tant que le client n'a pas reçu un `2xx`/`409`, il renvoie.
  Le serveur ne doit pas présumer de la bonne réception.
- **Horodatage** : stocker `timestamp` (client) et `received_at` (serveur) — le
  décalage révèle les tables dont l'horloge a dérivé.
- **Volumétrie** : photo JPEG en base64 ≈ +33 % ; prévoir au moins 2 Mo par
  `LINE_ADD` photo. Le client envoie **1 événement par requête**, 20 par passe
  de synchro (batch en extension §6).
- **Ordre** : le client envoie dans l'ordre `rowid` (ordre de création) ; le
  serveur n'a pas besoin d'ordonner, mais l'ordre reçu reflète le terrain.

## 4. GET /affectation — mission en cours

### 4.1 Requête

```
GET {api_base}/affectation
Authorization: Bearer {api_token}
X-Protocol-Version: 1.0
```

### 4.2 Réponse `200 OK`

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

| Clé `affectation` | Format | Rôle |
| --- | --- | --- |
| `destination` | string (code) | Destination chargée, choisie **et validée** par le serveur. |
| `dumping_area` | string (libellé) | Dumping area à rejoindre. |
| `mission` | string | Identifiant de la mission en cours. |
| `parcours` | JSON `[[easting, northing], …]` en **UTM mètres**, ≥ 2 points | Trajet prévu vers la dumping area. **C'est aussi la liste des waypoints** : `P[0]` = départ, `P[n-1]` = dumping area, les points intermédiaires sont les waypoints de passage. La tablette en tire deux usages locaux : détection d'écart (§4.4) et **calcul de progression** (§4.6) pour la carte et la barre de trajet de l'écran DT. |
| `alerte` | texte libre, vide = rien | Repli « option A » : message affiché tel quel par la tablette (geofences côté serveur). |
| *(autres clés)* | chaînes | Passées telles quelles ; la tablette n'affiche que ce qu'elle connaît. |

| Champ racine | Type | Rôle |
| --- | --- | --- |
| `affectation` | objet `clé → valeur` | Voir ci-dessus. |
| `valide_le` | ISO 8601 UTC | Instant de validation, affiché en badge par l'écran DT. |

### 4.3 Réponses possibles

| Code | Effet côté tablette |
| --- | --- |
| `200` avec au moins un champ | Remplacement **complet** de la table locale d'affectation (avec `valide_le`). |
| `200` sans champ | Aucune écriture. |
| `404` | Aucune affectation en cours — la dernière valeur connue est conservée. |
| `401/403/4xx/5xx`, timeout | Aucune écriture : une erreur ne peut jamais effacer une destination. |

### 4.4 Règles importantes

1. **Remplacement complet** : la réponse écrase toutes les clés précédentes.
   Si le `parcours` doit survivre à un changement de `dumping_area`, le serveur
   **doit renvoyer `parcours` à chaque passe** (le worker appelle l'endpoint
   toutes les 5 s).
2. **Détection d'écart** : seuils actuels de la tablette — sortie à **40 m**
   pendant **15 s**, retour sous **20 m** (hystérésis). Pendant l'alerte, **chaque
   mesure GPS rejoue un bip + une vibration** et un bandeau rouge affiche
   l'écart en mètres. Voir `PARAMETRES.md` §3.
3. **`parcours` malformé** (JSON invalide, moins de 2 points) : la détection
   locale se désactive silencieusement, la tablette se rabat sur `alerte`.
4. **`alerte` + `parcours`** : les deux peuvent coexister ; le message local
   (écart chiffré) a la priorité d'affichage sur le texte serveur.

### 4.5 Exemple de production de `parcours`

Le serveur doit calculer un itinéraire routable (pas une ligne droite — les
pistes du site sont sinueuses) :

```
points = plusCourtChemin(graphePistes, positionActuelleDT, dumpingArea)
parcours = json.dumps([[int(e), int(n)] for (e, n) in points])   # UTM mètres
```

- source de géométrie : fichier de pistes du site (`Trails.geojson` côté
  poste de supervision DT Travel : `LineString` nommées, ex. `W.R1`) ;
- algorithme : Dijkstra/A* sur les extrémités de segments ;
- densification optionnelle (un point tous les ~50 m) pour lisser les virages ;
- UTM : même fuseau sur tout le site ; les positions GPS des tablettes sont
  déjà converties en `easting`/`northing` (mètres).

### 4.6 Calcul de progression côté tablette (barre de trajet + carte)

La progression du DT **n'est pas calculée par le serveur** : une fois la
polyline reçue, le temps réel est 100 % local (la tablette roule hors 4G).
Le serveur doit simplement garantir que `parcours` est renvoyé à chaque passe
(§4.4, règle 1). Côté tablette, à chaque mesure GNSS :

1. **Projection** de la position (easting/northing) sur chaque segment
   `[P[i], P[i+1]]` de la polyline → distance au segment + position projetée.
2. **Progression** = (longueurs cumulées des segments entièrement franchis
   + distance le long du segment courant) / longueur totale de la polyline.
3. **Anti-retour** : la progression ne décroît jamais (demi-tour, bruit GPS) —
   la tablette garde le maximum atteint sur l'affectation courante.
4. **Waypoint courant** = premier sommet non franchi : il est affiché sur la
   barre de trajet de l'écran DT (à sa fraction de la longueur totale) et le
   DT se positionne sur la carte **au point projeté**, jamais interpolé.
5. La polyline sert trois usages cohérents sur la même donnée : carte
   (superposée aux tuiles OpenStreetMap, en WGS84 converti), barre de
   progression, détection d'écart (§4.4).

Exigences de cohérence pour le serveur :

- **Départ de la polyline = point de départ du DT** (`positions` « DEPART »
  de la table locale) : c'est P[0] que la barre et la carte placent sur leur
  borne de gauche.
- **Fin = dumping area** : P[n-1] doit coïncider avec la position connue de
  la `dumping_area`, sinon la borne de droite et le drapeau divergent.
- **Même fuseau UTM** sur toute la polyline (le site est dans une zone).
- Un changement d'affectation (nouveau `parcours`) **réinitialise** la
  progression : la barre repart de zéro sur le nouveau trajet.

## 5. Recommandations de conception serveur

- Table `evenements` : `event_id` **PRIMARY KEY**, index sur
  (`source_device`, `timestamp`) pour le suivi de position.
- Table `affectation` : clé/valeur + `valide_le` ; une seule opération
  atomique de remplacement par passe.
- Stocker chaque `GPS_UPDATE` (ou agréger à la minute) pour rejouer un trajet
  dans l'interface de supervision.
- Le serveur peut calculer ses propres geofences (option A) : pour éviter les
  doublons, utiliser les **mêmes seuils** (40/20 m, 15 s) ou des seuils
  strictement plus larges que ceux de la tablette.
- Réponses lentes : le timeout client est de **15 s** ; garder
  `GET /affectation` < 1 s (c'est le chemin critique de l'écran DT).

## 6. Extension : batch (non implémentée côté client)

```
POST {api_base}/evenements/batch   { "events": [ enveloppe, … ] }
```

Réponse : tableau d'ACK par `event_id`. La version 1.0 du client envoie un
événement à la fois ; le batch est prévu pour les volumétries terrain.

## 7. Checklist de mise en service

- [ ] `POST /evenements` répond `202` avec ACK valide.
- [ ] Rejeu du même `event_id` → `409` (et pas un second enregistrement).
- [ ] Mauvais jeton → `401`, bon jeton + mauvais protocole → `400`.
- [ ] `GET /affectation` sans mission → `404` (et pas `200` vide).
- [ ] `200` avec `parcours` valide → la tablette affiche la destination, et
      l'écart se déclenche au-delà de 40 m pendant 15 s.
- [ ] `200` avec `parcours` valide → la barre de trajet et le marqueur DT de
      la carte suivent la progression GNSS réelle (projection sur la polyline,
      §4.6), et le waypoint courant est visible sur la barre.
- [ ] `parcours` renvoyé à chaque passe (§4.4) : une coupure de 4G pendant
      un changement de dumping area ne laisse pas la tablette avec l'ancien
      trajet.
- [ ] Réponse lente (>15 s) → la tablette ne perd rien (l'événement reste en
      file, la destination conservée).
