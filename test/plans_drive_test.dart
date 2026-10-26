import 'package:flutter_test/flutter_test.dart';
import 'package:ore_tracking/data/base_locale.dart';
import 'package:ore_tracking/data/transmetteur.dart';

/// Contrat de l'inventaire des plans (`?action=plans`) : la tablette doit
/// refleter exactement le dossier Drive. Un changement de nommage cote serveur
/// doit faire echouer ces tests plutot que laisser la Map vide en production.
void main() {
  test('inventaire nominal : carte, id et nom', () {
    final List<PlanDrive>? plans = PlanDrive.depuisJson(<String, Object?>{
      'ok': true,
      'plans': <Map<String, Object?>>[
        <String, Object?>{
          'carte': '232.5_OM_LWP2_235_230_106_3',
          'id': '1ZniDWD0LLmo8N8YsFKLq370-I7AlxSFE',
          'nom': '232.5_OM_LWP2_235_230_106_3.gif',
        },
      ],
    });
    expect(plans, isNotNull);
    expect(plans!, hasLength(1));
    expect(plans.first.carte, '232.5_OM_LWP2_235_230_106_3');
    expect(plans.first.id, '1ZniDWD0LLmo8N8YsFKLq370-I7AlxSFE');
  });

  test('sans champ carte : deduit du nom du fichier', () {
    final List<PlanDrive>? plans = PlanDrive.depuisJson(<String, Object?>{
      'ok': true,
      'plans': <Map<String, Object?>>[
        <String, Object?>{
          'drive_id': '1ZniDWD0LLmo8N8YsFKLq370-I7AlxSFE',
          'nom': '262.5_OM_LMP2_270_260_113_5.png',
        },
      ],
    });
    expect(plans!.single.carte, '262.5_OM_LMP2_270_260_113_5');
  });

  test('variante file_id + url Drive', () {
    final List<PlanDrive>? plans = PlanDrive.depuisJson(<String, Object?>{
      'plans': <Map<String, Object?>>[
        <String, Object?>{
          'file_id': 'AAAABBBBCCCCDDDDEEEE',
          'carte': '265_OM_LMP2_270_260_116_3',
        },
        <String, Object?>{
          'url': 'https://drive.google.com/file/d/1111AAAA2222BBBB3333/view',
          'name': 'plan_270_OM_LMP2_270_260_117_1.jpg',
        },
      ],
    });
    expect(plans!, hasLength(2));
    expect(plans[0].id, 'AAAABBBBCCCCDDDDEEEE');
    // Le prefixe `plan_` et l'extension sont retires du nom.
    expect(plans[1].carte, '270_OM_LMP2_270_260_117_1');
  });

  test('action non servie : null (le client ne touche a rien)', () {
    expect(
      PlanDrive.depuisJson(<String, Object?>{
        'ok': false,
        'erreur': 'action inconnue : plans',
      }),
      isNull,
    );
  });

  test('URL Drive directe construite depuis l identifiant', () {
    expect(
      BaseLocale.urlDrive('1ZniDWD0LLmo8N8YsFKLq370-I7AlxSFE'),
      'https://drive.google.com/uc?export=download&confirm=t'
      '&id=1ZniDWD0LLmo8N8YsFKLq370-I7AlxSFE',
    );
  });
}
