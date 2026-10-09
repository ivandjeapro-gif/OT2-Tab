# Plan — Moteur de synchro serveur (CDC §14-§17, REQ-011 à REQ-015)

## Constat

La base locale possède déjà la machine à états complète (`evenementsEnAttente`,
`marquerEnCours` → SENDING, `marquerSynchronise` → SYNCED, `remettreEnAttente` →
PENDING) et quatre émetteurs (`LINE_ADD`, `BLAST_LOCK`, `BLAST_UNLOCK`,
`BLAST_SEND`). **Rien n'appelle ces transitions** : la file ne descend jamais.

Manque :

- aucun package HTTP, aucun contrat d'API ;
- colonne `gateway_id` absente (l'enveloppe §12 l'exige) ;
- aucun backoff : `tentatives` est compté mais jamais exploité ;
- événement coincé en SENDING après un arrêt brutal → **invisible dans
  `nombreEnAttente`** (qui ne compte que PENDING) et jamais rejoué ;
- `_versionner` (migration §23) est vide ;
- `gsmOnline` est figé à `true`.

## Décisions actées

1. **Migration schéma v1 → v2** : colonnes `gateway_id` + `prochaine_tentative`,
   `_versionner` implémenté, `vers_modele` passe `1.0` → `2.0`.
2. **Worker pour les 3 rôles**, piloté par `gsmOnline` (§15/§16.3), avec garde
   `base.estPersistee` (sans fichier il n'y a rien à vider — cela protège aussi
   les widget tests, qui tournent en mémoire).

## Étapes

### 1. Contrat d'API — nouveau `docs/API_SYNCHRO.md` (document seul)

- `POST {api_base}/evenements`, enveloppe §12 :
  `{event_id, gateway_id, source_device, event_type, timestamp, payload}`.
- En-têtes : `Authorization: Bearer <api_token>`, `X-Gateway-Id`,
  `X-Protocol-Version: 1.0`.
- Réponses : `202 ACK {event_id, status, received_at}` ;
  `409` doublon **idempotent** → traité comme un ACK (REQ-015) ;
  `401/403` → arrêt + message ; `422` → événement rejouable ;
  `5xx`/réseau/timeout → retour PENDING (REQ-013).
- Batch `/evenements/batch` documenté en extension (non implémenté).
- Configuration lue dans `meta` : `api_base`, `api_token`, `vers_protocole`.

### 2. Base locale — `lib/data/base_locale.dart` (migration v2)

- `versionModele = 2` ; `versions['vers_modele'] = '2.0'`.
- `_creer` : ajoute `gateway_id TEXT NOT NULL DEFAULT ''` et
  `prochaine_tentative INTEGER` au CREATE `evenements`.
- `_versionner(db, de, vers)` : si `de < 2`, deux `ALTER TABLE ... ADD COLUMN`.
- `_evenement()` : renseigne `gateway_id` (`declarerPasserelle()`, défaut =
  `_appareil`).
- À l'ouverture : `UPDATE evenements SET etat='PENDING' WHERE etat='SENDING'`
  (reprise §24, corrige le compteur) + recalcul de `_enAttente`.
- Nouveaux publics :
  - `List<Map<String,Object?>> aTransmettre({int limite, DateTime maintenant})`
    (PENDING **et** `prochaine_tentative` échue, `ORDER BY rowid`) ;
  - `Future<void> planifierNouvelleTentative(String id, DateTime quand)` ;
  - `void journaliser(String requete)` (§22, factorisé avec `_accepter`).

### 3. Client injectable — nouveau `lib/data/transmetteur.dart`

- `class Enveloppe` + `Enveloppe.depuisLigne(row)` (payload JSON décodé).
- `class ReponseServeur {int code; String? erreur; bool ok; bool doublon;}`.
- `abstract class Transmetteur { Future<ReponseServeur> envoyer(Enveloppe); }`.
- `TransmetteurHttp` : package **`http`** (`flutter pub add http`), timeout 15 s,
  `api_base`/`api_token` résolus à la volée via `base.meta`.
- `TransmetteurFactice` : scriptable (ACK / réseau / 409 / 500 / latence) et
  journalise ses appels pour les assertions.
- L'implémentation est injectée : `Synchronisation(base:, transmetteur:)`.

### 4. Worker — nouveau `lib/data/synchronisation.dart`

`class Synchronisation extends ChangeNotifier` :

- `demarrer()` / `arreter()` : `Timer.periodic(5 s)` ;
- `Future<int> unePasse()` :
  1. `reseauDisponible == false` → sortie immédiate, une notification « 4G hors
     ligne — N evenement(s) conserves » (REQ-012, aucune perte) ;
  2. lit `aTransmettre(limite: 20)` ;
  3. par événement : `marquerEnCours` → `envoyer` →
     `2xx`/`409` → `marquerSynchronise` + notification + `derniereSynchro` ;
     sinon → `remettreEnAttente` + `planifierNouvelleTentative`
     (backoff `min(5 s × 2^tentatives, 15 min)`) ;
  4. journalise chaque tentative/ACK dans `journal` (§22) ;
  5. se relance tant que la passe a progressé (plafond 10 itérations).
- Jamais de timer en test : les tests appellent `unePasse()` directement.

### 5. Intégration — `lib/state/session.dart`

- Champ `synchro` construit après `ouvrirBase()` (transmetteur HTTP réel).
- `connect()` démarre le worker (si `base.estPersistee`),
  `disconnect()` l'arrête.
- `set gsmOnline(bool)` répercute `synchro.reseauDisponible`.
- `derniereSynchro` n'est plus posée par la boucle de démo `_syncTick` : c'est
  l'ACK du worker qui la pose ; `_syncTick` garde les compteurs terrain.

### 6. Tests

`test/synchronisation_test.dart` (nouveau, fixtures `sqflite_common_ffi`
+ dossier temporaire, comme `base_locale_test.dart`) :

1. file vide → aucun appel réseau ;
2. 2 événements + ACK → tous SYNCED, `nombreEnAttente == 0`, enveloppe conforme
   §12 (UUID v4, `gateway_id`, `source_device`, horodatage UTC ISO, payload objet)
   ;
3. échec réseau → PENDING, `tentatives = 1`, `prochaine_tentative` dans le
   futur, et la passe suivante ne réessaie pas (backoff) ;
4. `gsmOnline = false` → 0 appel, file intacte (REQ-012) ;
5. `409` doublon → SYNCED (REQ-015) ;
6. `500` → pas de SYNCED, retour PENDING ;
7. mode mémoire → le worker ne plante pas et journalise.

`test/base_locale_test.dart` (ajouts) :

8. migration : fichier v1 ouvert en v2 → colonnes présentes, PENDING conservés ;
9. reprise : événements bloqués en SENDING → PENDING à la réouverture (§24) ;
10. assertion existante `vers_modele` : `1.0` → `2.0`.

### 7. Vérification

```
flutter analyze        # 0 issue
flutter test           # tests existants (9) + nouveaux
flutter build apk --debug
```

Réseau capricieux côté Gradle : la boucle `mavenLocal()` + curl en place depuis
le chantier précédent reste utilisable si un artefact manque.

## Hors périmètre (chantiers suivants)

**Chantier suivant acté — profils en table (§2.3, REQ-002)** : la liste des
profils n'est plus un `enum` codé en dur (`lib/models/models.dart:4`) mais une
table `profils (code, libelle, titre, role_cdc, icone, ordre, actif)` ;
`equipements` référence `profils.code`. La tablette (identité durable
`meta['device_id']`) devient distincte du profil qui lui est affecté. Reste en
code : `role_cdc` → comportement (écran + modules radio §19). Indépendant de ce
plan — le worker ne lit jamais la liste des profils.

Puis : écran supervision §21, couche radio BLE/Wi-Fi (§5/§7/§8), verrouillage
REQ-002, envoi par lot, journal des erreurs affiché à l'écran.
