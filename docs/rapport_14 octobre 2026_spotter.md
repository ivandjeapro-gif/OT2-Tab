# Rapport d'avancement — Profil SPOTTER

**Date :** 14/10/2026 · **Version :** 1.0.0+1 · **Projet :** ORE Tracking — tablette hors-ligne (réseau P2P Wi-Fi Direct / BLE) + serveur central Apps Script

**Périmètre de ce rapport :** le seul profil SPOTTER (tablette du spotter, supervision de la mine et des DT).

---

## 1. État du profil SPOTTER — 6/10

### 1.1 Fait ✅

1. **Écran spotter complet** (`lib/screens/spotter_screen.dart`) — écran principal structuré autour d'un shell de profil commun (`ProfileShell`) :
   - sélection du **blast** puis du **bloc** dans des listes lues depuis la base locale (jamais de liste en dur) ;
   - boutons d'action : `Select blast`, `Select bloc`, `Afficher map`, verrou (`Lock`) et envoi (`Envoyer`) ;
   - tableau des lignes du bloc courant, ajoutées par le bouton `+`.
2. **Saisie d'une ligne de relevé** (`_addRecord`) — formulaire en dialogue avec :
   - rappel non modifiable du contexte courant (Blast / Bloc / Carte) : une ligne rejoint toujours le bloc affiché, jamais un autre ;
   - **deux listes liées** : d'abord la famille de DT (DT 1500, DT 785…), puis un identifiant dans le lot de cette famille. Les identifiants étant non redondants sur tout le parc, changer de famille invalide proprement le numéro retenu ;
   - champ **Comment** libre ;
   - bouton **Picture** : choix de la source (appareil photo ou galerie), capture via `image_picker` (image redimensionnée 1600 px / qualité 85), vignette affichée avec possibilité d'effacer, gestion des erreurs (appareil indisponible → bascule galerie, photo illisible → message).
   - validation : un DT doit être choisi, sinon l'enregistrement est refusé avec message explicite.
3. **Verrouillage de bloc** (`_toggleLock`) — la validation porte sur la **paire blast/bloc** courante :
   - confirmation avec récapitulatif (nombre de lignes, nombre de lignes **sans picture**) ;
   - une fois verrouillé, le bloc n'accepte plus de nouvelles lignes ; les autres blocs du blast restent ouverts ;
   - déverrouillage possible en deux temps (confirmation).
4. **Envoi des données** (`_envoyer`) — périmètre paramétrable (`envoiMode` de la session) :
   - **blast entier**, **bloc courant** ou **blocs verrouillés** ;
   - contrôle de préparation avant d'ouvrir la fenêtre de confirmation (`_envoiPret`, `_motifEnvoiImpossible`) : verrouillage requis, présence de données, blast non déjà envoyé — chaque refus est annoncé en message explicite ;
   - fenêtre de confirmation annonçant le périmètre exact (lignes, blocs, carte) et la destination (point d'accès Master).
5. **Carte du blast** (`_afficherCarte`) — plan affiché en dialogue avec zoom (`InteractiveViewer`), message de secours si le plan est introuvable ; vignette d'aperçu sur le bouton `Afficher map`.
6. **Canal de notifications serveur → spotter** — poll `?action=notifications` (ordre du Boss) implémenté client et serveur ; notifications stockées en base locale (survivent au redémarrage), dédoublonnées par curseur, filtrées par profil, affichées en **bandeau rouge** avec bouton `OK` (acquittement opérateur).
7. **Relais multi-sauts des notifications Boss** — la notification peut suivre la chaîne complète : serveur → tablette DT (4G) → spotter via Wi-Fi Direct (message `NOTIFICATION` dans le protocole Wi-Fi et BLE), avec dédoublonnage multi-chemins (HTTP direct + relais local) via le même curseur.
8. **Réception des positions via le réseau P2P** — positions des autres profils reçues et affichées sur carte.
9. **Sélection persistée dans la session** — le blast/bloc/verrouillage vit dans `Session` (notifiable), l'écran se reconstruit dans un `ListenableBuilder` : aucun état figé.
10. **Responsive** — les cinq boutons d'action basculent sur deux rangées dès que la fenêtre fait moins de 700 px de contenu (mise en page calculée via `LayoutBuilder` + `MiseEnPage`).

### 1.2 Reste à faire 🔲

1. **Compte-rendu de mission** — synthèse de fin de mission (blocs verrouillés, lignes envoyées, photos manquantes) à générer et transmettre.
2. **Historique des événements consultable** — l'historique existe en base, il manque l'interface de lecture/relecture.
3. **Relecture des captures d'image (Picture)** — visionneuse des photos prises par ligne, avec filtrage (lignes sans picture, lignes envoyées…).
4. **Mode "au niveau de l'excavatrice"** — pilotage direct BLE en support ; les scénarios de reconnect ont été testés en banc, pas encore en conditions réelles.
5. **Envoi au serveur central finalisé** — l'envoi au point d'accès Master est câblé en session ; la chaîne complète jusqu'au serveur Apps Script reste à valider de bout en bout.
6. **Gestion des permissions runtime** — caméra/galerie demandées à chaud (premier usage) plutôt qu'à l'installation.

---

## 2. Synthèse en 10 points — fait / reste à faire (profil spotter)

1. ✅ **Écran spotter opérationnel** : sélection blast → bloc, tableau de lignes, ajout par `+`, verrou par bloc, envoi par périmètre.
2. ✅ **Saisie guidée et sécurisée** : listes DT liées depuis la base, contexte rappelé et non modifiable, DT obligatoire, erreurs explicites.
3. ✅ **Photos intégrées à la ligne** : source photo ou galerie, vignette, suppression, comptage des lignes sans picture au moment du verrouillage.
4. ✅ **Verrouillage et envoi contrôlés** : confirmation systématique, périmètre d'envoi paramétrable (blast / bloc / blocs verrouillés), refus annoncés avant d'ouvrir la fenêtre.
5. ✅ **Notifications Boss** : poll serveur + bandeau rouge avec acquittement, stockage local, dédoublonnage par curseur, relais multi-sauts Wi-Fi/BLE.
6. ✅ **Positions P2P** : réception et affichage des positions des autres profils sur carte.
7. ✅ **État piloté par session** : toute la sélection vit dans `Session` (notifiable), l'UI est réactive au moindre changement.
8. 🔲 **Compte-rendu de mission** : à générer (blocs verrouillés, lignes envoyées, photos manquantes).
9. 🔲 **Visionneuses** : historique des événements et relecture des pictures à ouvrir en interface.
10. 🔲 **Validation terrain** : mode BLE à proximité de l'excavatrice, chaîne d'envoi complète jusqu'au serveur central, permissions à chaud, tests en conditions réelles.

---

## 3. Risques et points d'attention

- **Taille des photos en mémoire** : les octets des images sont retenus en variable locale puis dans le modèle de ligne ; à surveiller si un bloc comporte beaucoup de lignes photographiées (pas de compression supplémentaire au-delà de 1600 px / 85).
- **Bascule Wi-Fi ↔ BLE** : le relais des notifications passe par les deux transports, mais le failover automatique entre les deux n'est pas encore validé.
- **Dépendance à la base locale** : les listes de familles de DT et d'identifiants viennent de la base ; une base vide (premier démarrage sans synchro) laisse les menus sans options — prévoir un état d'accueil explicite.
- **Envoi définitif** : `blast.envoye` fige le bouton d'envoi ; il n'existe pas encore de retrait ou correction possible après un envoi accidentel.

---

## 4. Conclusion

Le profil **SPOTTER** est fonctionnel en banc/développement sur son cœur métier : sélection blast/bloc, saisie de relevés avec photo, verrouillage par bloc et envoi par périmètre, notifications Boss affichées et acquittables, positions des autres profils reçues en P2P. Le reste concerne la **relecture** (historique, photos), le **compte-rendu**, le **mode support près de l'excavatrice** et la **validation terrain de bout en bout**.

**Note actuelle : 6/10** — socle métier complet, interface de relecture et workflows de fin de mission manquants.
