import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Verrouillage MATERIEL du role d'une tablette (30/10).
///
/// Pourquoi pas `meta['role_verrouille']` seul ? Cette cle vit dans la base
/// SQLite : elle disparait a la reinstallation et n'importe qui peut la
/// changer depuis l'ecran de connexion (un simple dialogue « changer de
/// role »). Sur un parc de chantier, une tablette qui change de role par
/// erreur casse toute la chaine BLE — c'est precisement le bug du 30/10.
///
/// Ici le role est lie au **numero de serie materiel** de la tablette
/// (`ro.serialno`, lisible par l'app sans permission particuliere). Une
/// tablette inconnue garde l'ancien comportement (role choisi a l'ecran) ;
/// une tablette listee ci-dessous est figee sur son role, reinstallation
/// comprise.
class VerrouRole {
  VerrouRole._();

  static const MethodChannel _canal = MethodChannel('ore_tracking/wifi_direct');

  /// Affectation du parc (30/10).
  ///
  /// Choisie a partir de l'historique des sessions terrain. Pour ajouter une
  /// tablette : ajouter une ligne `'serial': 'codeRole'`.
  static const Map<String, String> affectations = <String, String>{
    // Excavatrice : emet le GATT server et l'advertising BLE.
    'Active7NEU000566': 'ROLE_TAB3',
    // Premier DT : client BLE (se connecte a l'excavatrice).
    'Active7NEU000169': 'ROLE_TAB2',
    // Second DT : client BLE.
    'Active7NEU000562': 'ROLE_TAB2',
  };

  /// Libelles lisibles des roles, pour la surface de connexion.
  static const Map<String, String> libelles = <String, String>{
    'ROLE_TAB2': 'Dump Truck (DT)',
    'ROLE_TAB3': 'Excavatrice',
    'ROLE_TAB1': 'Spotter',
  };

  /// Serial de la tablette, ou chaine vide hors Android.
  static Future<String> serial() async {
    if (kIsWeb || !Platform.isAndroid) return '';
    try {
      final String? s = await _canal.invokeMethod<String>('serialMateriel');
      debugPrint('[VERROU] serialMateriel -> "$s"');
      return (s ?? '').trim();
    } catch (e) {
      // Canal absent (tests, autre plateforme) : on ne bloque rien, mais on
      // TRACE l'echec - un catch muet a deja coute une session de diagnostic.
      debugPrint('[VERROU] serialMateriel KO : $e');
      return '';
    }
  }

  /// Role verrouille pour cette tablette, ou `null` si elle n'est pas
  /// affectee (parc non provisionne) : l'ancien comportement s'applique.
  static Future<String?> roleImpose() async {
    final String s = await serial();
    final String? role = affectations[s];
    debugPrint('[VERROU] serial="$s" role="${role ?? '(non affectee)'}"');
    if (s.isEmpty) return null;
    return role;
  }

  /// Vrai si cette tablette est verrouillee sur un role fixe.
  static Future<bool> estVerrouillee() async => (await roleImpose()) != null;

  /// Libelle du role impose, ou chaine vide.
  static Future<String> libelleRoleImpose() async {
    final String? r = await roleImpose();
    if (r == null) return '';
    return libelles[r] ?? r;
  }
}
