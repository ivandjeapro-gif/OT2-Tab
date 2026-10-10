// Verifie le rendu des ecrans sur toutes les tailles utiles.
//
// Reproduit la vraie application : `ScreenUtilInit` est obligatoire, sinon
// `flutter_screenutil` ne peut pas lire la taille de l'ecran et leve
// `LateInitializationError` sur chacune de ses valeurs.
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ore_tracking/communication/alertes/alerter.dart';
import 'package:ore_tracking/data/base_locale.dart';
import 'package:ore_tracking/screens/dt_screen.dart';
import 'package:ore_tracking/screens/excavator_screen.dart';
import 'package:ore_tracking/screens/login_screen.dart';
import 'package:ore_tracking/screens/parametres_screen.dart';
import 'package:ore_tracking/screens/spotter_screen.dart';
import 'package:ore_tracking/state/session.dart';

import 'package:ore_tracking/main.dart' show kTailleReference;

void main() {
  // Les ecrans de connexion et de parametres n'appartiennent a aucun profil :
  // la session leur suffit telle quelle.
  final Map<String, Widget Function(Session)> ecrans = {
    'dt': (s) => DtScreen(session: s),
    'excavator': (s) => ExcavatorScreen(session: s),
    'spotter': (s) => SpotterScreen(session: s),
    'login': (s) => LoginScreen(session: s),
    'parametres': (s) => ParametresScreen(session: s),
  };

  for (final Size taille in const [
    Size(915, 412), Size(732, 412), Size(640, 360), Size(360, 640),
    Size(1024, 600), Size(600, 1024), Size(844, 390), Size(780, 360),
    Size(1120, 720), Size(2240, 1440),
  ]) {
    for (final entry in ecrans.entries) {
      testWidgets('${entry.key} ${taille.width}x${taille.height}', (tester) async {
        tester.view.physicalSize = taille;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final Session session = Session(alerter: AlerteFactice(), base: BaseLocale());
        final profil = session.base.profil(entry.key);
        if (profil != null) {
          session.profile = profil;
          session.deviceId = session.base.idsDuProfil(profil).first;
          session.deviceName = session.base.nomsDuProfil(profil).first;
        }

        final List<String> erreurs = <String>[];
        final avant = FlutterError.onError;
        FlutterError.onError = (FlutterErrorDetails d) =>
            erreurs.add(d.toString(minLevel: DiagnosticLevel.info));
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: kTailleReference,
            minTextAdapt: true,
            splitScreenMode: true,
            builder: (context, child) =>
                MaterialApp(home: entry.value(session)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        FlutterError.onError = avant;
        for (final String e in erreurs.toSet()) {
          // ignore: avoid_print
          print('ERREUR ${entry.key} ${taille.width}x${taille.height} : $e');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });
    }
  }
}
