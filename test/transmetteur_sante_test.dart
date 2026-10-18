import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ore_tracking/data/transmetteur.dart';

void main() {
  group('diagnosticSante — Apps Script', () {
    test('construit ?action=sante&token=... et resume la reponse', () async {
      Uri? requete;
      final TransmetteurHttp transmetteur = TransmetteurHttp(
        meta: (String cle) => switch (cle) {
          'api_base' => 'https://script.google.com/macros/s/ID/exec',
          'api_token' => 'secret-token',
          _ => null,
        },
        client: MockClient((http.Request request) async {
          requete = request.url;
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'service': 'ORE TRACKING serveur',
              'onglets': <String, Object?>{'evenements': 12, 'journal': 4},
              'pistes': 'ok',
              'plans': 'ok',
            }),
            200,
          );
        }),
      );

      final String resultat = await transmetteur.diagnosticSante();

      expect(requete?.queryParameters['action'], 'sante');
      expect(requete?.queryParameters['token'], 'secret-token');
      expect(resultat, contains('OK - serveur ORE TRACKING serveur joignable'));
      expect(resultat, contains('onglets: 2 lu(s)'));
      expect(resultat, contains('pistes: ok'));
      expect(transmetteur.serveurRepondu, isTrue);
    });

    test('un ok:false Apps Script est rapporte en erreur, jamais en succes',
        () async {
      final TransmetteurHttp transmetteur = TransmetteurHttp(
        meta: (String cle) => switch (cle) {
          'api_base' => 'https://script.google.com/macros/s/ID/exec',
          'api_token' => 'mauvais-token',
          _ => null,
        },
        client: MockClient((_) async => http.Response(
              jsonEncode(<String, Object?>{
                'ok': false,
                'erreur': 'token absent ou refuse',
              }),
              200,
            )),
      );

      expect(
        await transmetteur.diagnosticSante(),
        'ERREUR - token absent ou refuse',
      );
    });

    test('une api_base vide produit un message actionnable sans requete',
        () async {
      final TransmetteurHttp transmetteur = TransmetteurHttp(
        meta: (String cle) => cle == 'api_base' ? '' : null,
        client: MockClient((_) async => fail('aucun appel reseau attendu')),
      );

      expect(
        await transmetteur.diagnosticSante(),
        'ERREUR - api_base absente des parametres : rien a tester',
      );
    });
  });
}
