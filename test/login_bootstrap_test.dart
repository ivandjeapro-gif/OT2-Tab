import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ore_tracking/data/base_locale.dart';
import 'package:ore_tracking/data/transmetteur.dart';
import 'package:ore_tracking/state/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('ouvrirBase télécharge les référentiels avant le login si le serveur répond',
      () async {
    final BaseLocale base = BaseLocale();
    final Map<String, Object?> reponse = <String, Object?>{
      'ok': true,
      'referentiels_version': 1,
      'profils': <Map<String, Object?>>[
        <String, Object?>{
          'code': 'spotter',
          'libelle': 'Spotter',
          'titre': 'Spotter',
          'role_cdc': 'ROLE_TAB1',
          'icone': 'explore',
          'ordre': 1,
          'actif': 1,
        },
      ],
      'equipements': <Map<String, Object?>>[
        <String, Object?>{
          'profil': 'spotter',
          'id': 'TAB1-01',
          'nom': 'Spotter 01',
          'actif': 1,
        },
      ],
      'dts': <Map<String, Object?>>[
        <String, Object?>{'type': '1500', 'id': '01', 'actif': 1},
      ],
    };
    final Session session = Session(
      base: base,
      transmetteur: TransmetteurHttp(
      meta: (String cle) => switch (cle) {
        'api_base' => 'https://script.google.com/macros/s/TEST/exec',
        'api_token' => 'token',
        _ => null,
      },
        client: MockClient((http.Request request) async {
          expect(request.url.queryParameters['action'], 'referentiels');
          return http.Response(jsonEncode(reponse), 200);
        }),
      ),
    );

    await session.ouvrirBase();

    expect(base.profilsActifs.single.code, 'spotter');
    expect(base.idsDuProfil(base.profilsActifs.single), <String>['TAB1-01']);
    expect(base.typesDT.single.code, '1500');
    session.dispose();
  });
}
