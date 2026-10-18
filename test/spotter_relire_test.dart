import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ore_tracking/communication/alertes/alerter.dart';
import 'package:ore_tracking/data/base_locale.dart';
import 'package:ore_tracking/main.dart' show kTailleReference;
import 'package:ore_tracking/models/models.dart';
import 'package:ore_tracking/screens/spotter_screen.dart';
import 'package:ore_tracking/state/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('les panneaux de relecture s ouvrent et le filtre photo fonctionne',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1120, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final BaseLocale base = BaseLocale(blasts: <Blast>[
      Blast.legacy(
        numero: '501',
        carte: 'A1',
        plan: 'assets/images/cartes/plans/119_A1.jpg',
        blocs: <BlocTravail>[
          BlocTravail(
            numero: '3',
            carte: 'A1',
            lignes: <LigneBlast>[
              const LigneBlast(time: '08h00', dt: '1500', idDt: '01'),
              const LigneBlast(time: '08h10', dt: '1500', idDt: '08'),
            ],
          ),
        ],
      ),
    ]);
    final Session session = Session(alerter: AlerteFactice(), base: base);
    session.selectionnerBlast('501');

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: kTailleReference,
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (_, _) => MaterialApp(home: SpotterScreen(session: session)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Captures'));
    await tester.pumpAndSettle();
    expect(find.text('Captures (Picture)'), findsOneWidget);
    expect(find.text('Toutes (2)'), findsOneWidget);
    await tester.tap(find.text('Sans photo (2)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('DT 1500 n01'), findsOneWidget);
    expect(find.textContaining('DT 1500 n08'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Historique'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Journal ('), findsOneWidget);
    expect(find.textContaining('Notifications Boss ('), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Compte-rendu'));
    await tester.pumpAndSettle();
    expect(find.textContaining('COMPTE-RENDU DE MISSION - SPOTTER'), findsOneWidget);
    expect(find.textContaining('BLAST 501'), findsOneWidget);
    await tester.tap(find.text('Copier'));
    await tester.pumpAndSettle();
    expect(find.text('Compte-rendu de mission'), findsNothing);
  });
}
