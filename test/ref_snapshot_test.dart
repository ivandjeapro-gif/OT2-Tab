import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ore_tracking/data/transmetteur.dart';

/// Validation du snapshot `referentiels` tel que le serveur Apps Script le
/// rend aujourd'hui (fichier JSON capture avec curl). Sert de garde-fou :
/// si l'on retouche les noms de champs cote serveur, ce test le dit avant
/// que la tablette ne reste bloquee sur « Aucun profil configure ».
void main() {
  test('snapshot referentiels serveur reel', () {
    final File f = File(r'D:\Temp\ref169.json');
    if (!f.existsSync()) {
      markTestSkipped('capture ref169.json absente');
      return;
    }
    final Object? brut = jsonDecode(f.readAsStringSync());
    final ReferentielsServeur r = ReferentielsServeur.depuisJson(brut);
    expect(r.profils.map((p) => p.code), <String>['DT', 'EXCAVATOR', 'SPOT']);
    expect(r.typesDT, isNotEmpty);
    // Chaque famille doit porter son role, sinon le profil reste vide.
    for (final t in r.typesDT) {
      expect(t.role, isNotEmpty, reason: 'type ${t.code} sans role');
    }
  });

  test('dts SANS colonne role : le role est deduit des equipements', () {
    // Forme actuelle de l'onglet `dts` : (type, id, actif) seulement.
    // Les machines viennent de `equipements`, qui porte le profil.
    final Map<String, Object?> brut = <String, Object?>{
      'ok': true,
      'referentiels_version': 1,
      'profils': <Map<String, Object?>>[
        <String, Object?>{'code': 'DT', 'libelle': 'Chauffeur', 'role_cdc': 'DT', 'actif': 1},
        <String, Object?>{
          'code': 'EXCAVATOR',
          'libelle': 'Excavator',
          'role_cdc': 'EXCAVATOR',
          'actif': 1,
        },
      ],
      'equipements': <Map<String, Object?>>[
        <String, Object?>{'profil': 'DT', 'id': '1', 'nom': 'DT 1', 'role': 'DT', 'actif': 1},
        <String, Object?>{
          'profil': 'EXCAVATOR',
          'id': 'PC-2000',
          'nom': 'EX 2000',
          'role': 'EXCAVATOR',
          'actif': 1,
        },
      ],
      'dts': <Map<String, Object?>>[
        <String, Object?>{'type': '1500', 'id': '1', 'actif': 1},
        <String, Object?>{'type': 'PC', 'id': 'PC-2000', 'actif': 1},
      ],
    };
    final ReferentielsServeur r = ReferentielsServeur.depuisJson(brut);
    final Map<String, String> roles = <String, String>{
      for (final t in r.typesDT) t.code: t.role,
    };
    expect(roles['1500'], 'DT');
    expect(roles['PC'], 'EXCAVATOR');
  });
}
