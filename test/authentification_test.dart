import 'package:flutter_test/flutter_test.dart';
import 'package:ore_tracking/data/base_locale.dart';
import 'package:ore_tracking/data/transmetteur.dart';
import 'package:ore_tracking/models/models.dart';
import 'package:ore_tracking/state/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Session.connect — authentification locale', () {
    late BaseLocale base;
    late Session session;
    late Profil excavator;

    setUp(() async {
      base = BaseLocale();
      final ReferentielsServeur referentiels = ReferentielsServeur(
        profils: const <Profil>[
          Profil(
            code: 'excavator',
            libelle: 'Excavator',
            titre: 'Excavator',
            roleCdc: BaseLocale.roleTab3,
            icone: 'construction',
            ordre: 1,
          ),
        ],
        equipements: const <EquipementServeur>[
          EquipementServeur(
            profil: 'excavator',
            id: 'TAB3-01',
            nom: 'Excavator 01',
          ),
        ],
        typesDT: const <TypeDT>[
          TypeDT(code: '1500', role: 'DT', ids: <String>['1']),
          TypeDT(code: 'EXCAVATOR', role: 'EXCAVATOR', ids: <String>['1']),
        ],
      );
      await base.appliquerReferentiels(referentiels);
      excavator = base.profil('excavator')!;
      session = Session(base: base);
    });

    tearDown(() => session.dispose());

    test('un equipement valide ouvre la session sans exiger masterConnected', () {
      expect(session.masterConnected, isFalse);

      final bool accepte = session.connect(
        selected: excavator,
        id: 'EXCAVATOR-1',
        name: 'EXCAVATOR 01 - EXCAVATOR',
      );

      expect(accepte, isTrue);
      expect(session.profile?.code, 'excavator');
      expect(session.deviceId, 'EXCAVATOR-1');
      expect(session.deviceName, 'EXCAVATOR 01 - EXCAVATOR');
      expect(session.masterConnected, isFalse);
    });

    test('un equipement absent du referentiel reste refuse', () {
      final bool accepte = session.connect(
        selected: excavator,
        id: 'TAB3-INCONNU',
        name: 'Excavator Inconnu',
      );

      expect(accepte, isFalse);
      expect(session.profile, isNull);
      expect(session.deviceId, isEmpty);
      expect(session.deviceName, isEmpty);
    });
  });
}
