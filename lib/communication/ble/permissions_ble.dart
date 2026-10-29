import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Demande des permissions BLE **runtime** au premier lancement (Android 12+).
///
/// Le manifeste de l'application declare deja toutes les permissions BLE
/// (`BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`,
/// `ACCESS_FINE_LOCATION`). Mais sur Android 12 (API 31) et au-dela, ce sont
/// des permissions **runtime** : declarees ne veut pas dire accordees. Sans
/// cette demande explicite, l'advertising du role peripherique (excavatrice)
/// et le scan du role central (DT) echouent **silencieusement** — la couche
/// croit demarrer, rien ne circule.
///
/// Le BLE est le seul moyen d'echange qui soit activable par l'application :
/// contrairement au hotspot Wi-Fi, `BLUETOOTH_ADVERTISE` n'est soumis a
/// aucun privilege systeme. C'est pourquoi on s'en occupe ici.
///
/// Sur les autres plateformes (Windows, web, iOS), il n'y a rien a demander :
/// l'appel est un no-op qui rend `true`.
class PermissionsBle {
  PermissionsBle._();

  /// Vrai sur Android : la seule plateforme ou la demande runtime s'applique
  /// (iOS a son propre modele de popup, gere par les plugins BLE eux-memes).
  static bool get _estAndroid => !kIsWeb && Platform.isAndroid;

  /// Statuts individuels pour le DIAGNOSTIC sans boite de dialogue (28/10) :
  /// l'ecran de connexion verifie l'etat des accords runtime des l'ouverture
  /// et affiche un bandeau si un refus est detecte, sans rien demander.
  static Future<bool> get statutScan async {
    if (!_estAndroid) return true;
    try {
      return await Permission.bluetoothScan.isGranted;
    } catch (_) {
      return true;
    }
  }

  static Future<bool> get statutConnect async {
    if (!_estAndroid) return true;
    try {
      return await Permission.bluetoothConnect.isGranted;
    } catch (_) {
      return true;
    }
  }

  static Future<bool> get statutEmettre async {
    if (!_estAndroid) return true;
    try {
      return await Permission.bluetoothAdvertise.isGranted;
    } catch (_) {
      return true;
    }
  }

  /// Demande les permissions BLE et rend `true` si tout ce qui est necessaire
  /// est accorde.
  ///
  /// Sur Android < 12, seules `ACCESS_FINE_LOCATION` (scan) et les
  /// anciennes permissions `BLUETOOTH`/`BLUETOOTH_ADMIN` comptent : elles
  /// sont accordees a l'installation, la demande est alors instantanee.
  /// Sur Android >= 12, ce sont les trois `BLUETOOTH_*` qui sont demandees.
  ///
  /// Ne leve jamais : un refus rend `false`, l'appelant decide de continuer
  /// (la couche BLE reste simplement inoperante jusqu'a la prochaine
  /// tentative).
  static Future<bool> demander() async {
    if (!_estAndroid) return true;
    try {
      // Verifie d'abord si les permissions sont deja accordees :
      // appeler `.request()` sur des permissions deja accordees peut renvoyer
      // un resultat vide ou `denied` sur certaines versions d'Android si
      // aucune boite de dialogue n'est montree.
      bool scan = await Permission.bluetoothScan.isGranted;
      bool connecter = await Permission.bluetoothConnect.isGranted;
      bool emettre = await Permission.bluetoothAdvertise.isGranted;

      if (!connecter || (!scan && !emettre)) {
        final Map<Permission, PermissionStatus> resultats =
            await <Permission>[
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
          Permission.locationWhenInUse,
        ].request();

        scan = resultats[Permission.bluetoothScan]?.isGranted ?? scan;
        connecter =
            resultats[Permission.bluetoothConnect]?.isGranted ?? connecter;
        emettre =
            resultats[Permission.bluetoothAdvertise]?.isGranted ?? emettre;
      }

      final bool ok = (scan && connecter) || (emettre && connecter);
      debugPrint('[PERM_BLE] scan=$scan, connect=$connecter, emettre=$emettre -> $ok');
      return ok;
    } catch (e) {
      debugPrint('[PERM_BLE] exception : $e');
      return true;
    }
  }

  /// Vrai si l'utilisateur a coche « ne plus demander » : l'appelant peut
  /// alors proposer d'ouvrir les reglages systeme.
  static Future<bool> refuseDefinitivement() async {
    if (!_estAndroid) return false;
    try {
      final PermissionStatus statut = await Permission.bluetoothScan.status;
      return statut.isPermanentlyDenied;
    } catch (_) {
      return false;
    }
  }
}
