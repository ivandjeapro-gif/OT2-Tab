import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Provisionnement d'une tablette par le SaaS (30/10).
///
/// POURQUOI CE FICHIER PLUTOT QU'UN BUILD PAR TABLETTE.
///
/// L'approche `--dart-define=ROLE=...` grave le role dans le binaire : c'est
/// inviolable, mais elle impose au SaaS de RECOMPILER l'APK pour chaque
/// tablette (1 a 3 minutes chacune, plus un runner Flutter cote serveur, plus
/// N APK a stocker et versionner). A l'echelle d'un parc, c'est un piege.
///
/// Ici l'APK est UNIQUE. Le SaaS deverse un petit JSON dans le dossier prive
/// de l'application juste apres l'installation :
///
///   adb shell "run-as com.oretracking.ore_tracking \
///       sh -c 'mkdir -p files && cat > files/provisionnement.json'" \
///       <<< '{"role":"ROLE_TAB3","label":"EXCAVATOR 32","serial":"...","gele":true}'
///
/// Au demarrage :
///   - fichier present et lisible -> le role est FIGE, un seul profil est
///     cliquable sur l'ecran de connexion ;
///   - fichier absent -> comportement historique (choix libre), ce qui permet
///     de continuer a utiliser l'app hors provisionnement.
///
/// Le fichier vit dans `getApplicationSupportDirectory()` (donnees privees de
/// l'app) : il survit a `adb install -r` mais disparait avec `uninstall`.
/// Le SaaS le repousse alors en une commande — c'est le seul cout.
class Provisionnement {
/// Nom du fichier attendu, relatif au dossier de donnees de l'app.
  static const String nomFichier = 'provisionnement.json';

  /// Etat charge une fois au demarrage (memoire, pas de relecture par build).
  static Provisionnement? _instance;

  /// Role impose (`ROLE_TAB1` Spotter, `ROLE_TAB2` DT, `ROLE_TAB3` Excavatrice).
  final String role;

  /// Libelle lisible affiche a l'operateur (« EXCAVATOR 32 - HYUNDAI »).
  final String label;

  /// Serial attendu de la tablette. Sert de garde : si le JSON a ete copie
  /// sur la mauvaise tablette, on refuse le verrou plutot que de figer un
  /// role qui ne correspond pas au materiel.
  final String serial;

  /// Vrai quand le role est fige (un seul profil cliquable).
  final bool gele;

  const Provisionnement({
    required this.role,
    required this.label,
    required this.serial,
    required this.gele,
  });

  /// Vrai si un provisionnement actif a ete charge.
  static bool get actif => _instance != null;

  /// Provisionnement courant, ou `null` si la tablette n'est pas provisonnee.
  static Provisionnement? get courant => _instance;

  /// Charge le fichier de provisionnement. A appeler une fois au demarrage,
  /// avant de construire l'ecran de connexion.
  ///
  /// Ne leve jamais : un fichier absent ou illisible laisse l'app en mode
  /// libre (comportement historique), ce qui evite de bloquer une tablette
  /// sur une erreur de format.
  static Future<Provisionnement?> charger({String? dossier}) async {
    if (kIsWeb) return null;
    // En test, aucun canal natif : on ne tente pas la lecture (l'appel
    // MethodChannel sans mock laisse un timer en attente et fait echouer les
    // tests d'ecrans). Le provisionnement est un mecanisme de terrain.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    try {
      // DEUX EMPLACEMENTS, DANS CET ORDRE (fix 30/10) :
      //
      // 1. stockage EXTERNE de l'app :
      //    /sdcard/Android/data/<pkg>/files/provisionnement.json
      //    → ecrivable par le SaaS avec un simple `adb push`, SANS `run-as`.
      //      C'est indispensable : `run-as` echoue sur un APK release
      //      (« package not debuggable »), donc le dossier prive interne est
      //      inaccessible en production.
      // 2. dossier prive interne (`filesDir`) : utilise en debug, et si le
      //    SaaS a un jour la possibilite d'y ecrire.
      final List<String> candidats = <String>[
        if (dossier != null) dossier,
        ...await _dossiersPossibles(),
      ];
      File? f;
      for (final String base in candidats) {
        if (base.isEmpty) continue;
        final File essai = File('$base${Platform.pathSeparator}$nomFichier');
        if (await essai.exists()) {
          f = essai;
          debugPrint('[PROVISION] trouve dans $base');
          break;
        }
      }
      if (f == null) {
        debugPrint('[PROVISION] aucun fichier : mode libre');
        return null;
      }
      // BOM UTF-8 : db push depuis Windows en depose un. jsonDecode le
      // refuse (« Unexpected character »), ce qui laissait la tablette en mode
      // libre malgre un fichier valide. On le retire explicitement.
      String brut = await f.readAsString();
      // TOLERANCE AU BOM (fix 30/10) : PowerShell Set-Content -Encoding UTF8`r
      // et beaucoup d'editeurs prependent EF BB BF. Dart le conserve et
      // jsonDecode echoue alors que le fichier est valide -> mode libre
      // silencieux (constate en terrain).
      if (brut.isNotEmpty && brut.codeUnitAt(0) == 0xFEFF) {
        brut = brut.substring(1);
      }
      brut = brut.trimLeft();
      if (brut.isNotEmpty && brut.codeUnitAt(0) == 0xFEFF) {
        brut = brut.substring(1);
      }
      brut = brut.trim();
      final Object? json = jsonDecode(brut);
      if (json is! Map<String, Object?>) {
        debugPrint('[PROVISION] format invalide');
        return null;
      }
      final String role = '${json['role'] ?? ''}'.trim();
      if (role.isEmpty) {
        debugPrint('[PROVISION] role absent');
        return null;
      }
      final Provisionnement p = Provisionnement(
        role: role,
        label: '${json['label'] ?? ''}'.trim(),
        serial: '${json['serial'] ?? ''}'.trim(),
        gele: json['gele'] == true,
      );
      _instance = p;
      debugPrint(
        '[PROVISION] role=${p.role} label="${p.label}" gele=${p.gele}',
      );
      return p;
    } catch (e) {
      debugPrint('[PROVISION] lecture impossible : $e');
      return null;
    }
  }

  /// Dossier de donnees de l'application (`/data/data/<pkg>/files`).
  ///
  /// On evite `path_provider` : le paquet n'est pas forcement present, et un
  /// simple appel au canal natif suffit. En cas d'echec, on retombe sur une
  /// valeur vide et le provisionnement reste inactif.
  static const MethodChannel _canal = MethodChannel('ore_tracking/wifi_direct');

  /// Diagnostic affiche dans le bandeau temporaire de l'ecran de connexion.
  static String diagnostic = '(non execute)';

  static Future<List<String>> _dossiersPossibles() async {
    final List<String> sortie = <String>[];
    diagnostic = 'canal...';
    // Externe d'abord : seul emplacement ecrivable par `adb push` en release.
    final String? ext = await _invoke('dossierDonneesExterne');
    diagnostic = 'ext=';
    if (ext != null && ext.isNotEmpty) sortie.add(ext.trim());
    // Interne (debug, tests).
    final String? inte = await _invoke('dossierDonneesApp');
    diagnostic = '$diagnostic | int=${inte ?? "NULL"}';
    if (inte != null && inte.isNotEmpty) sortie.add(inte.trim());
    return sortie;
  }

  static Future<String?> _invoke(String methode) async {
    try {
      return await _canal.invokeMethod<String>(methode);
    } catch (e) {
      debugPrint('[PROVISION] $methode KO : $e');
      return null;
    }
  }

  /// Verifie que le serial du fichier correspond bien a la tablette.
  ///
  /// Une erreur de copie (JSON pousse sur la mauvaise tablette) figerait un
  /// role faux : on prefere ignorer le provisionnement et rester en mode
  /// libre, visible dans le journal.
  static bool serialCorrespond(String serialTablette) {
    final Provisionnement? p = _instance;
    if (p == null) return false;
    if (p.serial.isEmpty) return true; // pas de garde demandee
    return p.serial == serialTablette;
  }

  /// Remet a zero (tests).
  @visibleForTesting
  static void reinitialiser() => _instance = null;
}
