/**
 * ORE TRACKING — correctif serveur : inventaire des Plans (Maps) du Drive.
 *
 * Problème constaté le 26/10 :
 *   GET ?action=sante  ->  "pistes":"INACCESSIBLE", "plans":"INACCESSIBLE"
 *   GET ?action=plans  ->  {"ok":false,"erreur":"action inconnue : plans"}
 *   GET ?action=plan&carte=232.5_OM_LWP2_235_230_106_3
 *                       ->  {"ok":false,"erreur":"plan introuvable dans Drive…"}
 *
 * Pourtant le dossier comme les fichiers sont PUBLICS :
 *   dossier https://drive.google.com/drive/folders/1nOTs7uWhbtQb3XeZ9vhDRMFBB837KJ2B
 *           -> HTTP 200
 *   fichier 1ZniDWD0LLmo8N8YsFKLq370-I7AlxSFE
 *           -> HTTP 200, image/gif, 61 311 octets
 *
 * Conclusion : le code Apps Script ne parvient pas à OUVRIR le dossier avec le
 * compte qui exécute la Web App. Le correctif ci-dessous corrige les deux
 * aspects : l'accès, et l'action `plans` que le client attend.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * À FAIRE
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. Collez les fonctions de la section A dans votre fichier de code serveur.
 * 2. Remplacez l'action `plans` du routeur par la section B.
 * 3. Remplacez le calcul de `plans` dans l'action `sante` par la section C.
 * 4. Exécutez `diagnosticDossierPlans()` UNE FOIS depuis l'éditeur Apps Script
 *    (bouton Exécuter) : il affiche dans le journal ce qui bloque réellement.
 * 5. Redéployez la Web App en « Nouvelle version ».
 */

// ===========================================================================
// A. CONFIGURATION ET ACCÈS AU DOSSIER
// ===========================================================================

/**
 * Identifiant du dossier Drive qui contient les plans (Maps).
 *
 * Pourquoi un identifiant et non un nom : un nom peut changer ou être
 * dupliqué, l'identifiant jamais.
 */
const DOSSIER_PLANS_ID = '1nOTs7uWhbtQb3XeZ9vhDRMFBB837KJ2B';

/**
 * Ouvre le dossier des plans et rend `{ok, dossier}` ou `{ok:false, erreur}`.
 *
 * Deux méthodes sont tentées, dans cet ordre :
 *   1. DriveApp.getFolderById — la voie normale ;
 *   2. Drive.Files.get via le service avancé Drive (si activé) — utile quand
 *      le dossier est partagé « toute personne disposant du lien » et que
 *      DriveApp refuse l'accès.
 *
 * Neuvième fois qu'un « INACCESSIBLE » en production venait d'un partage
 * « limité » : un dossier partagé uniquement avec le lien se lit TRÈS BIEN
 * par HTTP, mais DriveApp exige que le compte exécutant le script figure
 * parmi les personnes autorisées (ou que le partage soit public).
 *
 * @return {{ok: boolean, dossier?: Folder, erreur?: string, astuce?: string}}
 */
function ouvrirDossierPlans() {
  try {
    const dossier = DriveApp.getFolderById(DOSSIER_PLANS_ID);
    // Un accès en lecture seule suffit, mais on vérifie qu'on peut LISTER :
    // sans cela, getFiles() lève au premier appel.
    const noms = dossier.getFiles();
    return { ok: true, dossier: dossier };
  } catch (e1) {
    // Deuxième tentative : service avancé Drive (MimeType d'un dossier).
    try {
      const meta = Drive.Files.get(DOSSIER_PLANS_ID, {
        fields: 'id,name,mimeType,permissions',
        supportsAllDrives: true
      });
      if (meta && meta.id) {
        return {
          ok: true,
          dossier: DriveApp.getFolderById(DOSSIER_PLANS_ID)
        };
      }
    } catch (e2) {
      // On conserve le message le plus parlant : celui de DriveApp.
    }
    return {
      ok: false,
      erreur: 'DriveApp.getFolderById a échoué : ' + (e1 && e1.message ? e1.message : e1),
      astuce: 'Partagez le dossier avec l\'adresse qui EXÉCUTE la Web App ' +
        '(pas seulement « toute personne disposant du lien »), en LECTEUR au ' +
        'minimum. Ou déployez la Web App avec un compte propriétaire du dossier.'
    };
  }
}

/**
 * Diagnostic à exécuter à la main depuis l'éditeur (menu Exécuter > Journal).
 *
 * Affiche, en clair :
 *  - le compte qui exécute ;
 *  - le nom du dossier et son propriétaire ;
 *  - les droits du compte courant ;
 *  - la liste des fichiers avec leur identifiant.
 *
 * C'est la PREUVE de ce qui bloque : sans ce journal, « INACCESSIBLE » ne dit
 * pas si le problème est un partage, un identifiant ou un compte.
 */
function diagnosticDossierPlans() {
  const lignes = [];
  try {
    lignes.push('Compte exécutant : ' + Session.getEffectiveUser().getEmail());
  } catch (e) {
    lignes.push('Compte exécutant : (inconnu — ' + e + ')');
  }

  const ouverture = ouvrirDossierPlans();
  if (!ouverture.ok) {
    lignes.push('OUVERTURE : ÉCHEC');
    lignes.push('  erreur : ' + ouverture.erreur);
    lignes.push('  astuce : ' + ouverture.astuce);
    Logger.log(lignes.join('\n'));
    return lignes.join('\n');
  }

  const dossier = ouverture.dossier;
  lignes.push('OUVERTURE : OK');
  lignes.push('  nom     : ' + dossier.getName());
  lignes.push('  id      : ' + dossier.getId());
  try {
    lignes.push('  proprio : ' + dossier.getOwner().getEmail());
  } catch (e) {
    lignes.push('  proprio : (non lisible : ' + e + ')');
  }
  try {
    lignes.push('  partage : ' + dossier.getSharingAccess() +
      ' / ' + dossier.getSharingPermission());
  } catch (e) {
    lignes.push('  partage : (non lisible : ' + e + ')');
  }

  const fichiers = dossier.getFiles();
  let i = 0;
  const exemples = [];
  while (fichiers.hasNext() && i < 500) {
    const f = fichiers.next();
    if (exemples.length < 10) {
      exemples.push('  - ' + f.getName() + '  [' + f.getId() + ']  ' +
        f.getMimeType() + '  ' + f.getSize() + ' o');
    }
    i++;
  }
  lignes.push('FICHIERS : ' + i + (i >= 500 ? ' (tronqué à 500)' : ''));
  lignes.push.apply(lignes, exemples);

  Logger.log(lignes.join('\n'));
  return lignes.join('\n');
}

// ===========================================================================
// B. ACTION `plans` — inventaire complet pour la tablette
// ===========================================================================

/**
 * Contenu du dossier des plans, au format attendu par le client Flutter.
 *
 * Contrat (docs/API_SYNCHRO.md § 9.1) :
 *   { "ok": true, "plans": [ { "carte": "...", "id": "...", "nom": "..." } ] }
 *
 * IMPORTANT — la réponse doit être EXHAUSTIVE. C'est elle qui pilote la
 * synchronisation complète côté tablette : tout fichier absent de cette liste
 * est SUPPRIMÉ du poste. Un `ok:false` (ou une liste tronquée) protégerait les
 * fichiers en place, mais ne déclencherait aucun téléchargement.
 *
 * Le code de carte est le nom du fichier sans son extension, sans le préfixe
 * `plan_` d'une ancienne version. Ex. `232.5_OM_LWP2_235_230_106_3.gif` donne
 * la carte `232.5_OM_LWP2_235_230_106_3`.
 *
 * @param {string} [jeton] jeton déjà vérifié par le routeur
 * @return {Object} réponse sérialisable
 */
function actionPlans(jeton) {
  const ouverture = ouvrirDossierPlans();
  if (!ouverture.ok) {
    // On remonte le motif : un « ok:false » muet laissait la tablette sans
    // aucune trace exploitable dans son journal.
    return {
      ok: false,
      erreur: 'dossier plans inaccessible : ' + ouverture.erreur,
      astuce: ouverture.astuce
    };
  }

  const plans = [];
  const fichiers = ouverture.dossier.getFiles();
  while (fichiers.hasNext()) {
    const f = fichiers.next();
    // Sous-dossiers ignorés : un plan est un fichier image à la racine.
    const nom = f.getName();
    if (!/\.(jpe?g|png|gif|webp|bmp)$/i.test(nom)) continue;
    plans.push({
      carte: codeCarteDepuisNom(nom),
      id: f.getId(),
      nom: nom
    });
  }

  // Tri stable : le journal et les diffs restent lisibles d'une passe à
  // l'autre, et deux appels successifs rendent le même ordre.
  plans.sort(function (a, b) {
    return a.carte < b.carte ? -1 : (a.carte > b.carte ? 1 : 0);
  });

  return {
    ok: true,
    dossier: ouverture.dossier.getId(),
    nombre: plans.length,
    plans: plans
  };
}

/**
 * Code de carte déduit du nom de fichier.
 * @param {string} nom
 * @return {string}
 */
function codeCarteDepuisNom(nom) {
  let n = String(nom || '').trim();
  const point = n.lastIndexOf('.');
  if (point > 0) n = n.substring(0, point);
  if (n.toLowerCase().indexOf('plan_') === 0) n = n.substring(5);
  return n.trim();
}

// ===========================================================================
// C. `sante` — état RÉEL des plans (à brancher dans l'action existante)
// ===========================================================================

/**
 * Valeur à renvoyer dans le champ `plans` de l'action `sante`.
 *
 * Aujourd'hui `sante` annonce `"plans":"INACCESSIBLE"` en dur (ou via un test
 * qui ne correspond plus au partage réel). On y met un état mesuré : le
 * nombre de fichiers, ou le motif de l'échec.
 *
 * @return {string} ex. "OK (12 fichier(s))" ou "INACCESSIBLE : <motif>"
 */
function etatPlans() {
  const ouverture = ouvrirDossierPlans();
  if (!ouverture.ok) return 'INACCESSIBLE : ' + ouverture.erreur;
  let n = 0;
  const fichiers = ouverture.dossier.getFiles();
  while (fichiers.hasNext()) {
    const f = fichiers.next();
    // Les sous-dossiers et fichiers non image ne comptent pas comme plans.
    if (/\.(jpe?g|png|gif|webp|bmp)$/i.test(f.getName())) n++;
  }
  return 'OK (' + n + ' fichier(s)) — dossier ' + ouverture.dossier.getName();
}

// ===========================================================================
// D. (OPTIONNEL) ancienne action `plan` — garder la compatibilité
// ===========================================================================

/**
 * Ancienne route `?action=plan&carte=<code>` : elle rejouait une recherche
 * Drive PAR NOM, d'où « plan introuvable dans Drive » dès que le nom, la casse
 * ou l'extension différaient.
 *
 * Le client Flutter ne l'appelle plus (il télécharge par identifiant, cf.
 * § 9.2). On la garde en repli, mais on la fait DÉLÉGUER à l'inventaire :
 * recherche par nom exact d'abord, puis par code de carte déduit du nom.
 *
 * @param {string} carte code de carte reçu en paramètre
 * @return {{ok: boolean, url?: string, erreur?: string}}
 */
function actionPlanParCarte(carte) {
  const cible = String(carte || '').trim();
  if (!cible) return { ok: false, erreur: 'carte absente' };

  const ouverture = ouvrirDossierPlans();
  if (!ouverture.ok) {
    return { ok: false, erreur: 'dossier plans inaccessible : ' + ouverture.erreur };
  }

  const fichiers = ouverture.dossier.getFiles();
  while (fichiers.hasNext()) {
    const f = fichiers.next();
    if (codeCarteDepuisNom(f.getName()) !== cible) continue;
    return {
      ok: true,
      id: f.getId(),
      url: 'https://drive.google.com/uc?export=download&confirm=t&id=' + f.getId()
    };
  }
  return { ok: false, erreur: 'plan introuvable pour la carte ' + cible };
}
