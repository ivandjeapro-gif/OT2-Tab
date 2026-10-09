import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:proj4dart/proj4dart.dart' as proj;

import '../../data/base_locale.dart';

/// Source de position GPS abstraite (CDC §5, §12).
///
/// Les tablettes Android portent un GPS : le service le lit via `geolocator`
/// et pousse un evenement `GPS_UPDATE` dans la file (§12), comme toute ecriture
/// metier. L'interface est injectable : les tests utilisent un fournisseur
/// factice qui joue des positions sans materiel.
abstract class FournisseurPosition {
  /// Positions du device, au rythme du GPS. Ne leve jamais : un GPS absent
  /// ou refuse n'arrete pas l'application, il ne produit simplement rien.
  Stream<PositionTerrain> suivre();
}

/// Un point tel que le serveur l'attend (§5) : coordonnees minieres
/// (easting/northing, en metres) et altitude.
class PositionTerrain {
  const PositionTerrain({
    required this.easting,
    required this.northing,
    required this.elevation,
    this.horodatage,
    this.wgs84,
  });

  final int easting;
  final int northing;
  final int elevation;
  final DateTime? horodatage;

  /// Position WGS84 source, pour la carte de suivi (§21).
  final ({double lat, double lng})? wgs84;
}

/// Fournisseur reel : le GPS du device (Android, ou capteur de localisation
/// Windows).
///
/// La position arrive en WGS84 (degres) : elle est convertie en coordonnees
/// minieres UTM (easting/northing) avant emission, car c'est le format que
/// le serveur analyse (§5) et que les ecrans affichent deja.
///
/// Les deux plateformes n'ont pas le meme modele de permission :
/// - Android : permission runtime a demander a la premiere utilisation ;
/// - Windows : pas de permission runtime, mais le service de localisation
///   du systeme peut etre eteint — on le teste avant de s'abonner.
/// Dans tous les cas d'echec, le flux se termine vide : l'application
/// continue sans position plutot que de planter.
class GpsReel implements FournisseurPosition {
  GpsReel({
    this.intervalle = const Duration(seconds: 5),
    this.filtreDistance = 5,
  });

  /// Cadence d'echantillonnage : le GPS rafraichit plus vite que besoin,
  /// la file d'evenements n'a pas a enfler pour rien.
  final Duration intervalle;

  /// Filtre de distance (metres) : aucune mesure n'est produite tant que le
  /// device n'a pas bouge de cette distance — les vehicules immobiles ne
  /// font pas gonfler la file ni rejouer l'alerte.
  final double filtreDistance;

  /// Vrai sur Android/iOS : il faut demander la permission avant de lire.
  /// Sur web la permission est portee par le navigateur et demandee au
  /// premier appel a [geo.Geolocator] lui-meme ; [Platform] y est de toute
  /// facon indisponible (dart:io non exploitable dans le navigateur).
  static bool get _permissionsRuntime =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  Stream<PositionTerrain> suivre() async* {
    if (_permissionsRuntime) {
      // Android/iOS : permission runtime demandee une fois, refus -> flux
      // vide, l'app vit quand meme.
      geo.LocationPermission permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
      }
      if (permission == geo.LocationPermission.denied ||
          permission == geo.LocationPermission.deniedForever) {
        return;
      }
    }
    // Service de localisation eteint (Windows : capteur systeme ; Android :
    // GPS desactive) : idem, rien a produire.
    if (!await geo.Geolocator.isLocationServiceEnabled()) {
      return;
    }
    await for (final geo.Position p in geo.Geolocator.getPositionStream(
      locationSettings: geo.LocationSettings(
        accuracy: geo.LocationAccuracy.best,
        // geolocator attend des metres entiers.
        distanceFilter: filtreDistance.round(),
        timeLimit: null,
      ),
    )) {
      yield PositionTerrain(
        easting: Utm.depuisWgs84(p.latitude, p.longitude).$1,
        northing: Utm.depuisWgs84(p.latitude, p.longitude).$2,
        elevation: p.altitude.round(),
        horodatage: p.timestamp,
        wgs84: (lat: p.latitude, lng: p.longitude),
      );
    }
  }
}

/// Conversion WGS84 -> UTM (easting/northing), via proj4dart.
///
/// Le site de travail tient dans une seule zone UTM : la zone est deduite du
/// fuselage (bande de 6 degres), la projection est la vraie UTM WGS84. Les
/// resultats sont arrondis en entiers — le serveur et les ecrans ne lisent
/// jamais de decimales (§5).
class Utm {
  Utm._();

  /// Convertit (lat, lng) WGS84 en (easting, northing) UTM.
  static (int, int) depuisWgs84(double lat, double lng) {
    // Les zones sont numerotees 1..60 pour lng -180..+180 : la formule
    // standard est floor((lng+180)/6) **+1** — sans le +1, lng 3° tombe
    // dans la zone 30 (6°O..0°) et l'easting sort du fuseau de ~500 km.
    final int zone = (((lng + 180) / 6).floor() + 1).clamp(1, 60);
    final String definition =
        '+proj=utm +zone=$zone +datum=WGS84 +units=m +no_defs';
    final proj.Projection utm = proj.Projection.parse(definition);
    final proj.Point point = proj.Projection.WGS84.transform(
      utm,
      proj.Point(x: lng, y: lat),
    );
    return (point.x.round(), point.y.round());
  }
}

/// Service qui suit la position du device et pose un evenement par mesure.
///
/// Branche sur la base : chaque mesure devient un `GPS_UPDATE` en file
/// `PENDING` (CDC §12), transmis au serveur comme les autres ecritures.
/// Serveur TAB 2 comme client TAB 3 : la passerelle relaie les GPS_UPDATE
/// recus du BLE dans la meme file.
class ServicePosition {
  ServicePosition({
    required this.base,
    FournisseurPosition? fournisseur,
    this.intervalle = const Duration(seconds: 5),
    this.filtreDistance = 5,
  }) : _fournisseur = fournisseur ??
            GpsReel(intervalle: intervalle, filtreDistance: filtreDistance);

  final BaseLocale base;
  final FournisseurPosition _fournisseur;
  final Duration intervalle;

  /// Filtre de distance (metres) applique par le GPS reel, lus dans
  /// `meta.filtre_distance_gps_m` a l'ouverture de la base.
  final double filtreDistance;

  StreamSubscription<PositionTerrain>? _sub;
  PositionTerrain? _derniere;

  /// Chaque mesure, diffusee en direct (flux broadcast).
  ///
  /// C'est l'entree de la detection d'ecart : la session s'abonne et compare
  /// chaque position au parcours recu du serveur, sans modifier le service.
  final StreamController<PositionTerrain> _mesures =
      StreamController<PositionTerrain>.broadcast();

  /// Mesures du GPS, au rythme de [intervalle] et du filtre de distance.
  Stream<PositionTerrain> get mesures => _mesures.stream;

  /// Derniere mesure connue, pour les ecrans (easting/northing/elevation §21).
  PositionTerrain? get derniere => _derniere;

  bool get actif => _sub != null;

  /// Demarre la surveillance GPS. Idempotent.
  void demarrer() {
    if (_sub != null) return;
    _sub = _fournisseur.suivre().listen(
      (PositionTerrain p) {
        _derniere = p;
        base.evenementPosition(p);
        _mesures.add(p);
      },
      onError: (Object _) {
        // Un GPS qui tombe n'arrete rien : la prochaine mesure reprendra.
        // Sur desktop, geolocator peut lancer une exception plateforme si le
        // service de localisation disparait en cours de route.
      },
      cancelOnError: false,
    );
  }

  void arreter() {
    _sub?.cancel();
    _sub = null;
  }
}

/// Fournisseur factice : positions scriptees, pour les tests et le banc.
class GpsFactice implements FournisseurPosition {
  GpsFactice(this.positions);

  /// Mesures a emettre, dans l'ordre. Vide ou epuise -> plus rien.
  final List<PositionTerrain> positions;

  @override
  Stream<PositionTerrain> suivre() async* {
    for (final PositionTerrain p in List<PositionTerrain>.of(positions)) {
      yield p;
    }
  }
}

/// Fournisseur de démonstration « hors parcours » : rejoue, en boucle, un
/// scénario réaliste de sortie de route.
///
/// Scénario (coordonnées UTM fictives autour d'un parcours en ligne droite) :
/// 1. le DT roule SUR le parcours (aucune alerte) ;
/// 2. il quitte la route progressivement (détour) — l'écart dépasse 40 m
///    pendant plus de 15 s → détection d'écart → alerte + bip + vibration ;
/// 3. il revient sur le parcours → alerte s'éteint ;
/// 4. après une pause, le scénario repart (boucle, pour une démo continue).
///
/// C'est un fournisseur comme un autre : la session ne sait pas qu'elle est
/// en démo, tout le reste (détection d'écart, alerter, badges) fonctionne
/// exactement comme en production.
class GpsDemoOffroad implements FournisseurPosition {
  GpsDemoOffroad({
    this.intervalle = const Duration(seconds: 2),
    this.eastingDepart = 320453,
    this.northingDepart = 920443,
  });

  /// Cadence des mesures simulées (2 s : assez rapide pour une démo vivante).
  final Duration intervalle;

  /// Point de départ du scénario (coordonnées de la session).
  final int eastingDepart;
  final int northingDepart;

  @override
  Stream<PositionTerrain> suivre() async* {
    int e = eastingDepart;
    int n = northingDepart;
    // Étapes du scénario : (avancée le long du parcours, écart latéral).
    // La ligne 1 suit la route (écart ~0), la 2 s'en écarte progressivement,
    // la 3 y revient, la 4 marque une pause avant de reboucler.
    final List<List<int>> script = <List<int>>[
      // 1. Sur le parcours (~15 s de démo à 2 s/mesure).
      [0, 0], [50, 0], [100, 0], [150, 0], [200, 5], [250, 0], [300, 0],
      // 2. Détour : l'écart croît vite → dépasse 40 m → alerte.
      [350, 15], [400, 30], [450, 60], [500, 80], [550, 100],
      [600, 110], [650, 115], [700, 120], [750, 125], [800, 130],
      // 3. Retour au parcours : l'écart redescend sous 20 m.
      [850, 90], [900, 50], [950, 25], [1000, 10], [1050, 0], [1100, 0],
      [1150, 0],
      // 4. Petite pause sur place avant de reboucler.
      [1150, 0], [1150, 0],
    ];

    while (true) {
      for (final List<int> etape in script) {
        final int avance = etape[0];
        final int ecart = etape[1];
        yield PositionTerrain(
          easting: e + avance,
          northing: n + ecart,
          elevation: 260,
          horodatage: DateTime.now(),
          // Le parcours de démo est écrit en UTM : conversion WGS84 inverse
          // approximative pour la carte (lat ≈ northing/111320, lng ajusté
          // par cos(lat)) — suffisant pour une démonstration.
          wgs84: (
            lat: (n + ecart) / 111320.0,
            lng: (e + avance) / (111320.0 * 0.60),
          ),
        );
        await Future<void>.delayed(intervalle);
      }
    }
  }
}
