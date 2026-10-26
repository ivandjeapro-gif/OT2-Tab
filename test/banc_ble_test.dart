import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ore_tracking/communication/ble/banc_ble.dart';
import 'package:ore_tracking/communication/ble/ble_gateway.dart';
import 'package:ore_tracking/communication/ble/ble_protocole.dart';
import 'package:ore_tracking/data/base_locale.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Communication BLE entre les tablettes, sur le banc (`BancBle`).
///
/// Chaine visee (CDC §7, §8, §9, §17, REQ-018) :
///
///   Spotter --(saisie)--> Excavatrice (TAB3, emet) --(BLE)--> DT (TAB2, client)
///
/// Ce que ces tests verrouillent — les defauts qui faisaient passer le lien
/// BLE pour « en pause » alors que le code existait :
/// 1. `evenementsPourRelais` doit emettre le marqueur `EVENEMENT`, pas
///    `EVENT` : le gateway ignore tout autre type ;
/// 2. le gateway doit acquitter ce qu'il recoit, sinon le relais renvoie le
///    meme evenement a chaque passe ;
/// 3. le DT doit pouvoir retenter seul (REQ-018), sinon un demarrage hors
///    portee immobilise le lien jusqu'a la reouverture de la session ;
/// 4. l'identite annoncee doit etre l'identifiant enrole, sinon refus.
void main() {
  /// Evenement tel qu'on l'obtient a la sortie de `BaseLocale.evenementRecu`
  /// (relais depuis le spotter).
  /// Enveloppe d'ACK du DT (meme forme que `Session._enveloppeAck`).
  Map<String, Object?> enveloppeAck(String eventId) =>
      <String, Object?>{'type': 'ACK', 'event_id': eventId};

  Map<String, Object?> evenementSpotter({String id = 'ev-1'}) =>
      <String, Object?>{
        'type': BleProtocole.typeEvenement,
        'event_id': id,
        'gateway_id': 'EXC-001',
        'source_device': 'S1',
        'event_type': 'LINE_ADD',
        'timestamp': '2026-10-20T07:35:00.000Z',
        'payload': <String, Object?>{'blast': '119', 'dt': '1500'},
      };

  group('Relais — marqueur du protocole de lien', () {
    test('evenementsPourRelais porte le type EVENEMENT dans un fichier reel',
        () async {
      // Sans base persistee, `evenementsPourRelais` rend une liste vide : le
      // test passait sans rien verifier. Ici la base est ouverte sur un
      // fichier temporaire, donc la vraie requete SQL tourne.
      final Directory dossier =
          await Directory.systemTemp.createTemp('ore_ble_relais');
      addTearDown(() async {
        try {
          await dossier.delete(recursive: true);
        } catch (_) {}
      });
      // sqflite ne fonctionne qu'en mobile : sous `flutter test` c'est la
      // variante FFI qui porte `openDatabase`.
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final BaseLocale base = BaseLocale()..declarerAppareil('EXC-001');
      await base.ouvrir(chemin: '${dossier.path}/test.db');
      addTearDown(base.fermer);

      base.evenementRecu(evenementSpotter(id: 'relais-1'));
      // L'insertion est mise en file d'ecriture : sans cette attente, la
      // lecture SQL part avant que la ligne existe.
      await base.attendreEcritures();
      final List<Map<String, Object?>> file =
          await base.evenementsPourRelais();

      expect(file, hasLength(1));
      expect(file.single['type'], BleProtocole.typeEvenement,
          reason: 'un type EVENT serait ignore par le gateway BLE et Wi-Fi');
      expect(file.single['event_id'], 'relais-1');
      expect(file.single['source_device'], 'S1');
      expect((file.single['payload'] as Map)['blast'], '119');
    });
  });

  group('Excavatrice (TAB3, emet) <-> DT (TAB2, client)', () {
    late BancBle banc;
    late BleGateway gateway;
    late BleClient dt;
    late JournalBleMemoire gatewayJournal;

    setUp(() async {
      banc = BancBle();
      gatewayJournal = JournalBleMemoire();
      gateway = BleGateway(
        transport: banc.coteGateway,
        // Identifiants enroles, tels qu'ils sortent de `equipements`.
        idsAutorises: <String>{'1501'},
        journal: gatewayJournal,
      );
      await gateway.demarrer();

      dt = BleClient(
        transport: banc.coteClient,
        sourceDevice: '1501',
        role: BaseLocale.roleTab2,
      );
      // Excavatrice a portee du DT.
      banc.excavatriceDeRetour();
    });

    tearDown(() async {
      await dt.arreter();
      await gateway.arreter();
    });

    test('le DT s\'authentifie par handshake', () async {
      expect(await dt.connecter(), isTrue);
      expect(dt.connecte, isTrue);
      expect(gateway.clientsConnectes, contains('1501'));
    });

    test('un identifiant non enrole est refuse', () async {
      final BleClient intrus = BleClient(
        transport: banc.coteClient,
        sourceDevice: 'INTRUS',
        role: BaseLocale.roleTab2,
      );
      addTearDown(intrus.arreter);

      expect(await intrus.connecter(), isFalse);
      expect(intrus.connecte, isFalse);
      expect(gateway.clientsConnectes, isEmpty);
    });

    test('ce que l\'excavatrice relaie arrive au DT et est acquitte', () async {
      expect(await dt.connecter(), isTrue);

      final Completer<String> recu = Completer<String>();
      // Comme la session : stocker/accuser a la reception, et renvoyer l'ACK
      // sur le lien courant.
      dt.surEvenement = (Map<String, Object?> e) {
        unawaited(dt.envoyer(enveloppeAck('${e['event_id']}')));
        if (!recu.isCompleted) recu.complete('${e['event_id']}');
      };

      await gateway.diffuserEvenement(evenementSpotter(id: 'relais-1'));

      expect(
        await recu.future.timeout(const Duration(seconds: 2),
            onTimeout: () => ''),
        'relais-1',
        reason: 'le DT doit recevoir l\'evenement pousse par le relais',
      );

      // L'ACK du DT doit parvenir a l'excavatrice : c'est celui du protocole
      // (message ACK), qui purge sa file de relais. Sans lui, elle renvoyait
      // le meme evenement a chaque passe et le DT le recevait en boucle.
      final DateTime limite = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(limite) &&
          !gatewayJournal.lignes
              .any((String l) => l.contains('ACK recu de 1501'))) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        gatewayJournal.lignes.where(
            (String l) => l == 'BLE ACK recu de 1501 pour relais-1'),
        hasLength(1),
        reason: 'journal exc=${gatewayJournal.lignes.join(' / ')}',
      );
    });

    test('la file du DT part seule et se vide a l\'ACK', () async {
      expect(await dt.connecter(), isTrue);
      await dt.envoyer(evenementSpotter(id: 'dt-1'));

      // L'ACK du gateway arrive en microtask sur le lien simule.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(dt.fileAttente, isEmpty,
          reason: 'l\'ACK du gateway doit purger la file du DT');
    });

    test('REQ-018 : sans excavatrice, le DT se reconnecte seul', () async {
      banc.excavatriceHorsPortee();
      expect(await dt.connecter(), isFalse);
      expect(dt.connecte, isFalse);

      // Cadence courte : le banc n'attend pas les 10 s du terrain.
      dt.demarrerReconnexionAuto(cadence: const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(dt.connecte, isFalse, reason: 'hors portee : aucun lien');

      // L'excavatrice revient : la boucle doit la retrouver seule.
      banc.excavatriceDeRetour();
      final DateTime limite =
          DateTime.now().add(const Duration(seconds: 3));
      while (!dt.connecte && DateTime.now().isBefore(limite)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(dt.connecte, isTrue,
          reason: 'le lien BLE doit revenir sans action de l\'operateur');
      expect(gateway.clientsConnectes, contains('1501'));
    });

    test('une coupure marque le lien comme perdu', () async {
      expect(await dt.connecter(), isTrue);
      banc.couperLien();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(dt.connecte, isFalse,
          reason: 'un lien coupe ne doit pas rester affiche authentifie');
    });
  });
}
