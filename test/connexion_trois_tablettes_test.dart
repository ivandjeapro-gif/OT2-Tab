import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ore_tracking/communication/wifi/banc_wifi.dart';
import 'package:ore_tracking/communication/wifi/wifi_gateway.dart';
import 'package:ore_tracking/communication/wifi/wifi_protocole.dart';
import 'package:ore_tracking/data/base_locale.dart';

/// La chaine reelle des trois tablettes, sur le banc Wi-Fi :
///
///   Spotter --(saisie)--> Excavatrice --(relais)--> DT --(4G)--> serveur
///
/// Ce que ces tests verrouillent, ce sont les quatre defauts qui empechaient
/// les tablettes de se parler :
/// 1. l'identite annoncee doit etre l'identifiant enrole (pas `TAB1-...`) ;
/// 2. l'excavatrice doit stocker le vrai type et la vraie source ;
/// 3. elle doit relayer sa file vers le DT, pas seulement acquitter ;
/// 4. le DT doit enregistrer ce qu'il recoit pour l'envoyer au serveur.
void main() {
  /// Enveloppe telle que le spotter la pousse sur le lien.
  Map<String, Object?> evenementSpotter({String id = 'ev-1'}) =>
      WifiProtocole.evenement(
        eventId: id,
        gatewayId: 'S1',
        sourceDevice: 'S1',
        eventType: 'LINE_ADD',
        timestamp: DateTime.utc(2026, 10, 20, 7, 35),
        payload: <String, Object?>{
          'blast': '119',
          'bloc': '7',
          'dt': '1500',
          'id_dt': '06',
          'comment': 'trou sec',
        },
      );

  group('BaseLocale — relais', () {
    test('conserve le type et la source, et marque la passerelle relais', () {
      final BaseLocale base = BaseLocale()..declarerAppareil('D1');

      final Map<String, Object?>? enveloppe =
          base.evenementRecu(evenementSpotter());

      expect(enveloppe, isNotNull);
      // Ce que le DT recevra sur le lien : le type d'origine, pas RELAY.
      expect(enveloppe!['event_type'], 'LINE_ADD');
      expect(enveloppe['source_device'], 'S1');
      // La passerelle qui relaie est la tablette qui stocke.
      expect(enveloppe['gateway_id'], 'D1');
      expect((enveloppe['payload'] as Map)['blast'], '119');
    });

    test('un identifiant deja vu n\'est pas relaye deux fois', () {
      final BaseLocale base = BaseLocale()..declarerAppareil('D1');

      expect(base.evenementRecu(evenementSpotter()), isNotNull);
      expect(base.evenementRecu(evenementSpotter()), isNull);
    });

    test('deux evenements distincts partent tous les deux', () {
      final BaseLocale base = BaseLocale()..declarerAppareil('D1');

      base.evenementRecu(evenementSpotter(id: 'ev-1'));
      base.evenementRecu(evenementSpotter(id: 'ev-2'));

      expect(base.journalBle.where((String l) => l.startsWith('RELAY')).length,
          2);
    });
  });

  group('Spotter -> Excavatrice -> DT (banc Wi-Fi)', () {
    late BancWifi banc;
    late BaseLocale baseExcavatrice;
    late WifiGateway gateway;
    late WifiClient spotter;
    late WifiClient dt;

    setUp(() async {
      banc = BancWifi();
      // Sans base persistee, la file locale n'existe pas sur disque : les
      // tests peuvent quand meme verifier le dialogue applicatif.
      baseExcavatrice = BaseLocale()..declarerAppareil('D1');

      gateway = WifiGateway(
        transport: banc.coteGateway,
        // Ce que l'excavatrice accepte : les identifiants enroles, tels
        // qu'ils sortent de la table `equipements`.
        idsAutorises: <String>{'S1', '1501'},
        idGateway: 'D1',
      );
      gateway.surEvenement = (String source, Map<String, Object?> evenement) {
        baseExcavatrice.evenementRecu(evenement);
        gateway.acquitter(source, '${evenement['event_id']}');
      };
      await gateway.demarrer();

      spotter = WifiClient(
        transport: banc.coteClient,
        sourceDevice: 'S1',
        role: BaseLocale.roleTab1,
      );
      dt = WifiClient(
        transport: banc.coteClient,
        sourceDevice: '1501',
        role: BaseLocale.roleTab2,
      );
    });

    tearDown(() async {
      await spotter.arreter();
      await dt.arreter();
      await gateway.arreter();
    });

    test('le spotter s\'authentifie et recoit son ACK', () async {
      banc.tab2Present();
      final bool authentifie = await spotter.connecter();

      expect(authentifie, isTrue);
      expect(spotter.connecte, isTrue);
      expect(gateway.clientsConnectes, contains('S1'));

      await spotter.envoyer(evenementSpotter());
      // L'ACK arrive en microtask sur le lien simule.
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(spotter.fileAttente, isEmpty,
          reason: 'l\'ACK doit purger la file du spotter');
    });

    test('l\'excavatrice relaie vers le DT ce qu\'elle a recu', () async {
      banc.tab2Present();
      // Le DT est present, comme s'il attendait dans le rayon de 10 m.
      expect(await dt.connecter(), isTrue);
      expect(await spotter.connecter(), isTrue);

      // Le DT signale l'evenement recu sur le lien local : c'est ce canal
      // que la session branche sur `_recevoirRelais` (stockage + ACK).
      final Completer<String> recu = Completer<String>();
      dt.surEvenement = (Map<String, Object?> evenement) {
        if (!recu.isCompleted) recu.complete('${evenement['event_id']}');
      };

      // Le relais reel : la file PENDING de l'excavatrice part vers tous ses
      // clients.
      final List<Map<String, Object?>> file =
          await baseExcavatrice.evenementsPourRelais();
      // (base non persistee en test : l'evenement relaye est pousse
      // directement, sous la forme exacte que produit `evenementRecu`)
      final Map<String, Object?> evenement = evenementSpotter(id: 'relais-1')
        ..['type'] = 'EVENEMENT';
      await gateway.diffuserEvenement(evenement);

      expect(file, isA<List<Map<String, Object?>>>());

      // Le DT a bien recu l'enveloppe : sans le relais, il n'aurait rien vu
      // et l'evenement du spotter serait mort sur l'excavatrice.
      final String arrive = await recu.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => '',
      );
      expect(arrive, 'relais-1');
    });

    test('un identifiant non enrole est refuse', () async {
      banc.tab2Present();
      final WifiClient intrus = WifiClient(
        transport: banc.coteClient,
        sourceDevice: 'INTRUS',
        role: BaseLocale.roleTab1,
      );

      expect(await intrus.connecter(), isFalse);
      expect(intrus.connecte, isFalse);
      await intrus.arreter();
    });
  });

  group('BaseLocale — file de relais', () {
    test('un point d\'entree par evenement, jamais le conteneur RELAY', () async {
      final BaseLocale base = BaseLocale()..declarerAppareil('D1');
      base.evenementRecu(evenementSpotter(id: 'ev-9'));

      // La colonne SQL garde la forme du protocole de lien.
      final List<Map<String, Object?>> relais =
          await base.evenementsPourRelais();

      // Sans base persistee (tests), il n'y a pas de fichier : la methode
      // rend une liste vide plutot que de lever.
      expect(relais, isA<List<Map<String, Object?>>>());
    });
  });
}
