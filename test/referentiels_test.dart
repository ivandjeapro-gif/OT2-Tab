import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ore_tracking/data/transmetteur.dart';
import 'package:ore_tracking/data/synchronisation.dart';
import 'package:ore_tracking/data/base_locale.dart';

Map<String, Object?> snapshotJson() => <String, Object?>{
      'ok': true,
      'referentiels_version': 1,
      'profils': <Map<String, Object?>>[
        <String, Object?>{
          'code': 'dt',
          'libelle': 'Driving Truck',
          'titre': 'DT',
          'role_cdc': 'ROLE_TAB2',
          'icone': 'local_shipping',
          'ordre': 1,
          'actif': 1,
        },
        <String, Object?>{
          'code': 'excavator',
          'libelle': 'Excavatrice',
          'titre': 'Excavatrice',
          'role_cdc': 'ROLE_TAB3',
          'icone': 'construction',
          'ordre': 2,
          'actif': 1,
        },
        <String, Object?>{
          'code': 'spotter',
          'libelle': 'Spotter',
          'titre': 'Spotter',
          'role_cdc': 'ROLE_TAB1',
          'icone': 'explore',
          'ordre': 3,
          'actif': 1,
        },
      ],
      'equipements': <Map<String, Object?>>[
        <String, Object?>{
          'profil': 'dt', 'id': '01', 'nom': 'DT 01', 'actif': 1,
        },
        <String, Object?>{
          'profil': 'excavator', 'id': '02', 'nom': 'Excavatrice 02', 'actif': 1,
        },
        <String, Object?>{
          'profil': 'spotter', 'id': '03', 'nom': 'Spotter 03', 'actif': 1,
        },
      ],
      'dts': <Map<String, Object?>>[
        <String, Object?>{'type': '1500', 'id': '01', 'actif': 1},
        <String, Object?>{'type': '1500', 'id': '08', 'actif': 1},
        <String, Object?>{'type': '785', 'id': '09', 'actif': 1},
      ],
    };

void main() {
  group('ReferentielsServeur', () {
    test('parse les profils, equipements et DT en conservant les identifiants', () {
      final ReferentielsServeur data =
          ReferentielsServeur.depuisJson(snapshotJson());

      expect(data.profils.map((p) => p.code), <String>['dt', 'excavator', 'spotter']);
      expect(data.profils[1].libelle, 'Excavatrice');
      expect(data.equipements.first.id, '01');
      expect(data.equipements.first.nom, 'DT 01');
      expect(data.typesDT.map((t) => t.code), <String>['1500', '785']);
      expect(data.typesDT.first.ids, <String>['01', '08']);
    });

    test('rejette un snapshot incomplet sans le convertir en listes vides', () {
      expect(
        () => ReferentielsServeur.depuisJson(<String, Object?>{
          'ok': true,
          'referentiels_version': 1,
          'profils': <Object?>[],
          'equipements': <Object?>[],
          'dts': <Object?>[],
        }),
        throwsFormatException,
      );
    });

    test('la route Apps Script et le jeton sont transmis dans la query', () async {
      Uri? requete;
      final TransmetteurHttp tx = TransmetteurHttp(
        meta: (String cle) => switch (cle) {
          'api_base' => 'https://script.google.com/macros/s/TEST/exec',
          'api_token' => 'token-test',
          _ => null,
        },
        client: MockClient((http.Request r) async {
          requete = r.url;
          return http.Response(jsonEncode(snapshotJson()), 200);
        }),
      );

      final ReferentielsServeur? data = await tx.lireReferentiels();

      expect(requete?.queryParameters['action'], 'referentiels');
      expect(requete?.queryParameters['token'], 'token-test');
      expect(data?.profils.length, 3);
    });

    test('une erreur HTTP ou un snapshot invalide rend null', () async {
      final TransmetteurHttp tx = TransmetteurHttp(
        meta: (String cle) => switch (cle) {
          'api_base' => 'https://script.google.com/macros/s/TEST/exec',
          'api_token' => 'token-test',
          _ => null,
        },
        client: MockClient((_) async => http.Response(
              jsonEncode(<String, Object?>{
                'ok': false,
                'erreur': 'referentiels absents ou incoherents',
              }),
              200,
            )),
      );
      expect(await tx.lireReferentiels(), isNull);
    });
  });

  group('Synchronisation des referentiels', () {
    test('snapshot transmis Ã  la base et panne prÃ©serve les valeurs existantes',
        () async {
      final BaseLocale base = BaseLocale();
      final TransmetteurFactice tx = TransmetteurFactice();
      final Synchronisation sync = Synchronisation(
        base: base,
        transmetteur: tx,
      );
      final ReferentielsServeur data =
          ReferentielsServeur.depuisJson(snapshotJson());
      tx.referentiels = data;
      tx.reponse = const ReponseServeur(code: 200);

      await sync.unePasseReferentiels();
      expect(base.profils.map((p) => p.code), contains('spotter'));
      expect(base.idsDuProfil(base.profil('dt')!), contains('01'));
      expect(base.idsDuType('1500'), <String>['01', '08']);

      tx.referentiels = null;
      await sync.unePasseReferentiels();
      expect(base.idsDuProfil(base.profil('dt')!), contains('01'));
      expect(base.idsDuType('1500'), <String>['01', '08']);
    });
  });
}
