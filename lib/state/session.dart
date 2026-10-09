import 'dart:async';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../communication/ble/ble_gateway.dart';
import '../communication/ble/transport_ble.dart';
import '../communication/ble/transport_central.dart';
import '../communication/ble/transport_peripherique.dart';
import '../communication/alertes/alerter.dart';
import '../communication/position/detection_ecart.dart';
import '../communication/position/service_position.dart';
import '../communication/wifi/transport_tcp.dart';
import '../communication/wifi/transport_wifi.dart';
import '../communication/wifi/wifi_gateway.dart';
import '../data/base_locale.dart';
import '../data/synchronisation.dart';
import '../data/transmetteur.dart';
import '../models/models.dart';
import 'etat_couche.dart';

/// Etat partage de l'application.
///
/// La boucle de synchro simule ici le serveur P2P permanent qui tourne en
/// tache de fond sur la tablette de l'excavatrice (point d'acces Master) :
/// chaque tick met a jour les compteurs et diffuse une notification.
///
/// La synchro **serveur** (CDC §14) est un sujet distinct : c'est
/// [synchro], qui vide la file `evenements` des que la 4G revient.
class Session extends ChangeNotifier {
  Session({AlerteMetier? alerter, BaseLocale? base})
      : alerter = alerter ?? AlerteSysteme(),
        base = base ?? BaseLocale() {
    _seedNotifications();
    synchro = Synchronisation(
      base: this.base,
      // L'URL et le jeton sont lus dans `meta` a chaque envoi : changer la
      // configuration ne demande aucun redemarrage.
      transmetteur: TransmetteurHttp(meta: this.base.meta),
      surMessage: push,
    );
  }

  /// Canal sonore + vibratoire de l'alerte hors-parcours : injectable pour
  /// que les tests comptent les declenchements au lieu de vibrer.
  final AlerteMetier alerter;

  /// Comparateur de position au parcours vers la dumping area (option B) :
  /// pures mathematiques, il ne connait ni le reseau ni le materiel.
  final DetecteurEcart detecteurEcart = DetecteurEcart();

  /// Base de donnees locale. Les listes deroulantes de l'ecran spotter lisent
  /// dedans, et aucune modification ne la contourne. Injectable pour que les
  /// tests y injectent des blasts de demo (`BaseLocale.blastsDemo()`).
  final BaseLocale base;

  /// Worker de synchro serveur (CDC §14) : vide la file `evenements`.
  ///
  /// Construit une seule fois avec la session ; demarre a la connexion, s'arrete
  /// a la deconnexion. Les tests le pilotent par [Synchronisation.unePasse].
  late final Synchronisation synchro;

  /// Ouvre le fichier local (CDC §13) et recharge les donnees du disque.
  ///
  /// Appelee par le splash : echoue silencieusement en « memoire seule » si le
  /// fichier est inaccessible, l'application ne s'arrete jamais la-dessus.
  ///
  /// [demoOffroad] : mode DEMONSTRATION (presentation). Injecte un parcours
  /// fictif dans la base et branche un GPS simulé qui le quitte puis y revient
  /// en boucle — la détection d'écart, l'alerte, le bip et la vibration
  /// fonctionnent exactement comme en production.
  Future<void> ouvrirBase({bool demoOffroad = false}) async {
    await base.ouvrir();
    push(
      base.estPersistee
          ? 'Base locale ouverte - ecritures sauvegardees sur disque'
          : 'Base locale indisponible - fonctionnement en memoire',
    );
    // Selection par defaut : le premier blast recu du serveur, s'il y en a
    // un. Sans blast (production neuve, attente serveur) la selection reste
    // vide et l'ecran l'affiche comme tel.
    if (base.numerosBlast.isNotEmpty) {
      selectionnerBlast(base.numerosBlast.first);
    }
    if (demoOffroad) {
      await _preparerDemoOffroad();
    }
    // Les seuils de detection et le GPS se parametrent dans l'ecran
    // Parametres : lus ici une premiere fois, relus par
    // [rechargerParametres] a chaque changement.
    _intervalleGps = _dureeMeta('intervalle_gps_s', 5);
    _filtreGps = _doubleMeta('filtre_distance_gps_m', 5);
    rechargerParametres();
    // Le GPS (§5) part avec la base : ses mesures finissent dans la meme
    // file d'evenements. Sur desktop sans capteur, le service reste
    // silencieux sans jamais planter. L'abonnement aux mesures se pose
    // AVANT le demarrage : la premiere mesure ne peut pas passer a cote.
    servicePosition = ServicePosition(
      base: base,
      fournisseur: demoOffroad ? GpsDemoOffroad() : null,
      intervalle: _intervalleGps,
      filtreDistance: _filtreGps,
    );
    _subMesures ??= servicePosition!.mesures.listen(traiterMesure);
    servicePosition!.demarrer();
    if (demoOffroad) {
      push('MODE DEMO OFFROAD actif - scenario de sortie de parcours en boucle');
    }
  }

  /// Preparatifs du mode démo : parcours fictif + affectation complète,
  /// pour que la détection d'écart (option B) trouve ses données.
  Future<void> _preparerDemoOffroad() async {
    // Parcours en ligne droite vers la dumping area (UTM, metres).
    const String parcours =
        '[[320453,920443],[320503,920443],[320553,920443],'
        '[320603,920443],[320653,920443],[320703,920443],'
        '[320753,920443],[320803,920443],[320853,920443],'
        '[320903,920443],[320953,920443],[321003,920443],'
        '[321053,920443],[321103,920443],[321153,920443],'
        '[321203,920443],[321253,920443],[321303,920443],'
        '[321353,920443],[321403,920443],[321453,920443],'
        '[321503,920443],[321553,920443],[321603,920443]]';
    await base.enregistrerAffectation(<String, String>{
      'destination': 'F5M',
      'dumping_area': 'RomPad 1',
      'parcours': parcours,
    });
  }

  /// Service de position du device (CDC §5) : demarre a l'ouverture de la
  /// base, arrete a la fermeture de la session.
  ServicePosition? servicePosition;

  StreamSubscription<PositionTerrain>? _subMesures;

  /// Evenements en attente de transmission vers le serveur (CDC §14, §21).
  int get enAttente => base.nombreEnAttente;

  /// Profil de la session, lu dans `base.profils()` au moment de la connexion.
  Profil? profile;
  String deviceId = '';
  String deviceName = '';

  bool masterConnected = false;

  /// Etat de la 4G (§15). Une coupure ne perd rien : elle arrete seulement
  /// les envois, la file reste en place et reprend seule au retablissement.
  bool get gsmOnline => synchro.reseauDisponible;

  set gsmOnline(bool valeur) {
    if (gsmOnline == valeur) return;
    synchro.reseauDisponible = valeur;
    if (valeur) {
      push('4G retablie - reprise de la synchronisation serveur');
      // Une passe immédiate au rétablissement (§15) : la nuée est animée
      // pendant l'échange tant qu'il reste quelque chose à vider.
      unawaited(_passeAvecAnimation());
    } else {
      push('4G perdue - les donnees restent en locale');
      // La nuée retombe : plus rien ne circule vers le serveur.
      synchroActive = false;
    }
    notifyListeners();
  }

  /// Vrai pendant un échange effectif avec le serveur (§14) : la nuée
  /// ([SyncCloudIcon]) s'anime tant que la file PENDING n'est pas vide.
  bool synchroActive = false;

  /// Une passe de synchro avec animation de la nuée : active tant que des
  /// événements restent à transmettre, éteinte dès que la file est vide.
  Future<void> _passeAvecAnimation() async {
    if (!base.estPersistee) return;
    synchroActive = true;
    notifyListeners();
    try {
      await synchro.unePasse();
    } finally {
      synchroActive = base.nombreEnAttente > 0;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------- reseau reel

  /// Abonnement a l'etat reel du reseau (connectivity_plus). Le badge 4G et
  /// la synchro serveur lisent la meme source : plus rien de simule.
  final Connectivity _apiReseau = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subConnectivite;

  /// Dernier etat lu chez le systeme, vide tant que la surveillance n'a pas
  /// rendu son premier resultat (badge Wi-Fi : « pas demarre »).
  List<ConnectivityResult> _connectivite = const <ConnectivityResult>[];

  /// Etat reseau courant, tel que lu chez le systeme.
  List<ConnectivityResult> get connectivite => _connectivite;

  /// Demarre l'ecoute de l'etat reseau du systeme : toute variation (Wi-Fi
  /// coupe, 4G perdue, retour a la portee) met a jour le badge et relance la
  /// synchro serveur. Sans cette ecoute, [gsmOnline] resterait au booleen de
  /// test initial.
  void demarrerSurveillanceReseau() {
    _subConnectivite ??= _apiReseau.onConnectivityChanged.listen(
      majConnectivite,
      onError: (Object _) {
        // Sur une plateforme ou connectivity_plus n'est pas implemente, on
        // ne plante pas : le badge reste dans son dernier etat connu.
      },
    );
    // Le stream ne se declenche qu'a la premiere variation : sans cet appel
    // initial, les badges resteraient dans l'etat « pas demarre » jusqu'a ce
    // que le reseau change reellement.
    _apiReseau
        .checkConnectivity()
        .then<void>(majConnectivite, onError: (Object _) {});
  }

  void arreterSurveillanceReseau() {
    _subConnectivite?.cancel();
    _subConnectivite = null;
  }

  /// Applique un etat reseau lu chez le systeme (ecouteur et tests).
  ///
  /// C'est la seule porte d'entree de la realite reseau dans la session :
  /// elle alimente le badge Wi-Fi ([etatWifiDevice]) et la 4G
  /// ([gsmOnline], d'ou [etat4G]).
  @visibleForTesting
  void majConnectivite(List<ConnectivityResult> resultats) {
    _connectivite = List<ConnectivityResult>.unmodifiable(resultats);
    final bool enLigne = resultats.any(
      (ConnectivityResult r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet,
    );
    gsmOnline = enLigne;
    // Meme si la 4G ne bouge pas (Wi-Fi -> ethernet), le badge Wi-Fi doit
    // se repeindre : il lit [_connectivite].
    notifyListeners();
  }

  // ---------------------------------------------------------- etats (badges)

  /// Badge Wi-Fi : lien vers le point d'acces Master (CDC §20.1).
  ///
  /// Rouge tant que la surveillance n'a rien lu ou que le Wi-Fi du device
  /// est absent (pas demarre / aucun retour), orange des que le radio est
  /// la sans session, vert une fois la session posee dessus.
  EtatCouche get etatWifiDevice {
    if (_connectivite.isEmpty) return EtatCouche.arret;
    final bool radio = _connectivite.any(
      (ConnectivityResult r) =>
          r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet,
    );
    if (!radio) return EtatCouche.arret;
    return masterConnected ? EtatCouche.connecte : EtatCouche.recherche;
  }

  /// Badge GPS (§5) : le recepteur externe branche en USB-C est-il lu ?
  ///
  /// Vert des que le service de position produit des mesures (derniere
  /// mesure recue), orange tant que le service tourne sans avoir rien rendu
  /// (acquisition en cours, GPS pas encore fixe), rouge si le service est
  /// arrete ou n'a jamais pu s'abonner (capteur absent, permission refusee).
  EtatCouche get etatGps {
    final ServicePosition? service = servicePosition;
    if (service == null || !service.actif) return EtatCouche.arret;
    return service.derniere == null ? EtatCouche.recherche : EtatCouche.connecte;
  }

  /// Badge 4G : retour effectif du serveur (CDC §21).
  ///
  /// Rouge si la boucle de synchro n'a pas ete lancee ou si aucune voie de
  /// retour n'existe, orange le temps d'attendre le premier retour, vert
  /// des que le serveur a repondu au moins une fois.
  EtatCouche get etat4G {
    if (!synchro.actif || !synchro.reseauDisponible) return EtatCouche.arret;
    return switch (synchro.serveurRepondu) {
      true => EtatCouche.connecte,
      false => EtatCouche.arret,
      null => EtatCouche.recherche,
    };
  }

  /// Badge BLE : lien etabli avec les excavatrices (TAB 2) ou avec le DT
  /// (TAB 3). Rouge = couche pas demarree, orange = demarree et en
  /// decouverte, vert = au moins un lien authentifie.
  EtatCouche get etatBle {
    if (!bleActif) return EtatCouche.arret;
    return liensBle > 0 ? EtatCouche.connecte : EtatCouche.recherche;
  }

  /// Nombre de liens BLE authentifies, lu sur le gateway (TAB 2) ou sur le
  /// client (TAB 3) plutot que sur un compteur que rien ne rafraichit.
  int get liensBle {
    final BleGateway? passerelle = _gatewayBle;
    if (passerelle != null) return passerelle.clientsConnectes.length;
    final BleClient? client = _clientBle;
    if (client != null) return client.connecte ? 1 : 0;
    return 0;
  }

  /// Badge Wi-Fi P2P : meme regle que [etatBle], couche TCP DT <-> spotter.
  EtatCouche get etatWifiP2p {
    if (!wifiActif) return EtatCouche.arret;
    return liensWifi > 0 ? EtatCouche.connecte : EtatCouche.recherche;
  }

  /// Nombre de liens Wi-Fi P2P authentifies (gateway pour le DT, client
  /// pour le spotter).
  int get liensWifi {
    final WifiGateway? passerelle = _gatewayWifi;
    if (passerelle != null) return passerelle.clientsConnectes.length;
    final WifiClient? client = _clientWifi;
    if (client != null) return client.connecte ? 1 : 0;
    return 0;
  }

  /// Blast et bloc actuellement affiches par l'ecran du spotter.
  ///
  /// La selection vit dans la session et pas dans l'ecran : elle doit survivre
  /// a un changement de profil, et tous les noeuds du reseau suivent le meme
  /// blast. Elle ne sert jamais a interdire la navigation : un blast verrouille
  /// reste consultable et on peut toujours passer a un autre. Vide au
  /// demarrage tant que le serveur n'a pas fourni de blast.
  String blastCourant = '';
  String blocCourant = '';

  /// Blast selectionne, ou null si le numero n'existe plus.
  Blast? get blast => base.parNumero(blastCourant);

  /// Bloc selectionne dans le blast courant, ou null s'il n'existe pas.
  BlocTravail? get bloc => blast?.bloc(blocCourant);

  /// Vrai quand le **bloc courant** est verrouille (paire blast/bloc, v6) :
  /// aucune ligne ne peut plus etre ajoutee dans ce bloc, les autres blocs
  /// du blast ne sont pas concernes.
  bool get verrouille => bloc?.verrouille ?? false;

  /// Mode d'envoi courant (`meta.envoi_mode`) : `blast`, `bloc` ou
  /// `verrouilles` — decide du perimetre du bouton « Envoyer ».
  String get envoiMode => base.envoiMode;

  // ---------------------------------------------------------- parametres

  /// Cadence GPS courante, lue dans `meta.intervalle_gps_s` (§5).
  late Duration _intervalleGps;

  /// Filtre de distance GPS courant, lu dans `meta.filtre_distance_gps_m`.
  late double _filtreGps;

  Duration get intervalleGps => _intervalleGps;
  double get filtreGps => _filtreGps;

  /// Relit les cles `meta` de l'ecran Parametres et les applique **en direct**
  /// : seuils de detection d'ecart (§4) puis, si la cadence ou le filtre GPS
  /// a bouge, redemarrage du service de position (§5).
  ///
  /// `api_base`, `api_token` et `envoi_mode` n'ont pas besoin d'etre
  /// recharge : ils sont relus a chaque envoi. Retourne false si un seuil
  /// incoherent est refuse (sortie >= entree) — la configuration precedente
  /// est alors conservee et l'ecran l'affiche.
  bool rechargerParametres() {
    final double entree = _doubleMeta('seuil_entree_m', 40);
    final double sortie = _doubleMeta('seuil_sortie_m', 20);
    final Duration delai = _dureeMeta('delai_confirmation_s', 15);
    final bool seuilsOk = detecteurEcart.configurer(
      seuilEntree: entree,
      seuilSortie: sortie,
      delaiConfirmation: delai,
    );

    final Duration intervalle = _dureeMeta('intervalle_gps_s', 5);
    final double filtre = _doubleMeta('filtre_distance_gps_m', 5);
    final bool gpsChange =
        intervalle != _intervalleGps || filtre != _filtreGps;
    _intervalleGps = intervalle;
    _filtreGps = filtre;
    if (gpsChange) _redemarrerGps();

    notifyListeners();
    return seuilsOk;
  }

  /// Redemarre le service GPS avec la cadence et le filtre courants.
  ///
  /// L'abonnement aux mesures est pose avant le demarrage, comme a
  /// l'ouverture de la base : la premiere mesure ne peut pas passer a cote.
  /// Un service jamais cree (base pas encore ouverte) reste inactif.
  void _redemarrerGps() {
    final ServicePosition? ancien = servicePosition;
    if (ancien == null) return;
    ancien.arreter();
    _subMesures?.cancel();
    _subMesures = null;
    servicePosition = ServicePosition(
      base: base,
      intervalle: _intervalleGps,
      filtreDistance: _filtreGps,
    );
    _subMesures = servicePosition!.mesures.listen(traiterMesure);
    servicePosition!.demarrer();
  }

  /// Entier positif lu dans `meta` (secondes), [defaut] si cle absente ou
  /// malformee : une saisie erronee ne casse jamais le demarrage.
  Duration _dureeMeta(String cle, int defaut) {
    final int v = int.tryParse(base.meta(cle) ?? '') ?? defaut;
    return Duration(seconds: v < 1 ? 1 : v);
  }

  /// Nombre decimal lu dans `meta` (metres), [defaut] si cle absente ou
  /// malformee.
  double _doubleMeta(String cle, double defaut) {
    final double v = double.tryParse(base.meta(cle) ?? '') ?? defaut;
    return v < 0 ? defaut : v;
  }

  /// Change de blast et se place sur son premier bloc.
  ///
  /// La carte n'est pas un choix a part : elle appartient au blast, donc
  /// charger le blast charge du meme coup sa carte.
  void selectionnerBlast(String numero) {
    final Blast? cible = base.parNumero(numero);
    if (cible == null) return;
    blastCourant = cible.numero;
    blocCourant = cible.blocs.isEmpty ? '' : cible.blocs.first.numero;
    notifyListeners();
  }

  /// Change de bloc a l'interieur du blast courant.
  void selectionnerBloc(String numero) {
    if (blocCourant == numero) return;
    blocCourant = numero;
    notifyListeners();
  }

  /// Categories de DT de la premiere liste du formulaire.
  List<TypeDT> get typesDT => base.typesDT;

  /// Lot de numeros du type choisi, pour la seconde liste deroulante.
  List<String> idsDuType(String codeType) => base.idsDuType(codeType);

  /// Vrai si ce numero de DT appartient bien a cette categorie.
  bool idAppartientAuType(String codeType, String id) =>
      base.typeDT(codeType)?.contient(id) ?? false;

  /// Plan JPG de la carte du blast courant.
  ///
  /// La carte etant celle du blast, il n'y a pas de choix a faire : le plan
  /// suit la selection du blast sans autre action.
  String? get planCourant => blast?.plan;

  /// Point de depart du trajet, lu dans la table des positions.
  ({double lat, double lng})? get positionDepart =>
      base.positionDe(BaseLocale.codeDepart);

  /// Position de la destination courante, si la base la connait.
  ({double lat, double lng})? get positionDestination =>
      base.positionDe(destination);

  /// Position du DT sur son trajet : interpolation entre le depart et la
  /// destination a l'avancement [routeProgress].
  ///
  /// On ne convertit pas les easting/northing simules : la carte et la barre
  /// de trajet doivent raconter la meme histoire, donc les deux lisent la
  /// meme table et le meme avancement.
  ({double lat, double lng})? get positionDt {
    final ({double lat, double lng})? depart = positionDepart;
    final ({double lat, double lng})? arrivee = positionDestination;
    if (depart == null || arrivee == null) return null;

    final double t = routeProgress.clamp(0.0, 1.0).toDouble();
    return (
      lat: depart.lat + (arrivee.lat - depart.lat) * t,
      lng: depart.lng + (arrivee.lng - depart.lng) * t,
    );
  }

  /// Ajoute une ligne au bloc courant, via la base.
  bool ajouterLigne(LigneBlast ligne) {
    final BlocTravail? cible = bloc;
    if (cible == null) return false;
    final bool ok = base.ajouterLigne(cible, ligne);
    if (!ok) push(base.refusEnCours ?? 'Ajout refuse');
    notifyListeners();
    return ok;
  }

  /// Validation du bloc courant (paire blast/bloc, v6) : la base compte les
  /// lignes de CE bloc, le ferme et journalise l'ecriture. Les autres blocs
  /// du blast restent ouverts tant qu'on ne les verrouille pas.
  void verrouillerBloc() {
    final Blast? blast = this.blast;
    final BlocTravail? cible = bloc;
    if (blast == null || cible == null) return;
    final int lignes = cible.nombreLignes;
    if (!base.verrouiller(cible)) {
      push(base.refusEnCours ?? 'Verrouillage refuse');
      notifyListeners();
      return;
    }
    push(
      'Bloc ${cible.numero} du blast ${blast.numero} verrouille - '
      '$lignes ligne(s) enregistreee(s)',
    );
    notifyListeners();
  }

  /// Reouverture du bloc courant pour reprendre la saisie. Les autres blocs
  /// verrouilles du blast ne sont pas touches.
  void deverrouillerBloc() {
    final Blast? blast = this.blast;
    final BlocTravail? cible = bloc;
    if (blast == null || cible == null) return;
    if (!base.deverrouiller(cible)) {
      push(base.refusEnCours ?? 'Deverrouillage refuse');
      notifyListeners();
      return;
    }
    push(
      'Bloc ${cible.numero} du blast ${blast.numero} deverrouille - '
      'saisie possible',
    );
    notifyListeners();
  }

  /// Transmet au point d'acces Master les donnees deja enregistrees.
  ///
  /// Le perimetre est celui du mode courant ([envoiMode]) : la base refuse si
  /// les conditions du mode ne sont pas remplies ou si le blast est deja
  /// parti : l'ecran n'affiche que le refus, il ne fait jamais l'envoi a la
  /// place.
  bool envoyerDonnees() {
    final Blast? cible = blast;
    if (cible == null) {
      push('Aucun blast selectionne : rien a envoyer');
      notifyListeners();
      return false;
    }
    final bool ok = base.envoyer(cible, numeroBloc: blocCourant);
    if (ok) {
      final String perimetre = switch (envoiMode) {
        BaseLocale.envoiModeBloc => 'Bloc $blocCourant du blast',
        BaseLocale.envoiModeVerrouilles => 'Blocs verrouilles du blast',
        _ => 'Blast',
      };
      push(
        '$perimetre ${cible.numero} envoye - donnees transmises '
        'au point d\'acces Master',
      );
    } else {
      push(base.refusEnCours ?? 'Envoi refuse');
    }
    notifyListeners();
    return ok;
  }

  int easting = 320453;
  int northing = 920443;
  int elevation = 260;

  int syncCount = 0;
  double routeProgress = 0.62;

  /// Destination courante : choisie **et validee par le serveur**.
  ///
  /// Vide tant que le serveur n'a rien renvoye : la carte reste alors sur son
  /// emplacement d'attente (`positionDestination` -> null -> placeholder)
  /// plutot que sur un point choisi ici. Aucun ecran n'ecrit cette valeur.
  String get destination => base.affectation('destination') ?? '';

  /// Dumping area courante, meme origine que [destination].
  String get dumpingArea => base.affectation('dumping_area') ?? '';

  /// Alerte poussée par le serveur (option A de la détection d'écart) : le
  /// serveur compare les positions GPS à ses geofences et pose un champ
  /// `alerte` dans `/affectation`. La tablette n'invente rien : elle affiche
  /// le message du serveur, et vide quand rien n'est alerté.
  String get alerteServeur => base.affectation('alerte') ?? '';

  /// Alerte effective de l'ecran DT : l'ecart local (option B) a la priorite,
  /// le repli `alerte` du serveur prend le relais quand aucun parcours n'a
  /// ete recu. Vide = rien a afficher.
  String get alerteCourante {
    if (detecteurEcart.actif && detecteurEcart.horsParcours) {
      final int ecart = (detecteurEcart.derniereDistance ?? 0).round();
      final String cible = dumpingArea.isEmpty ? 'la dumping area' : dumpingArea;
      return 'Hors parcours - ecart $ecart m du trajet vers $cible';
    }
    return alerteServeur;
  }

  /// Vrai tant qu'une alerte est affichable (bandeau + signal sonore).
  bool get alerteActive => alerteCourante.isNotEmpty;

  /// Vrai pendant que l'alerte reste active entre deux mesures : c'est la
  /// memorisation du front montant/descendant de [alerteCourante].
  bool _alerteActive = false;

  /// Une mesure GPS : met a jour la detection d'ecart et signale l'alerte.
  ///
  /// Choix terrain : **chaque mesure pendant l'alerte rejoue le bip et la
  /// vibration** (un chauffeur distrait doit etre repris a chaque position,
  /// pas une seule fois). Sans mesure (GPS off, vehicule immobile sous le
  /// filtre de 5 m), rien ne sonne : le bandeau, lui, reste affiche.
  @visibleForTesting
  void traiterMesure(PositionTerrain mesure) {
    detecteurEcart.parcours(base.affectation('parcours'));
    detecteurEcart.evaluer(
      easting: mesure.easting.toDouble(),
      northing: mesure.northing.toDouble(),
      maintenant: mesure.horodatage ?? DateTime.now(),
    );

    final bool actif = alerteActive;
    if (actif) alerter.jouer();

    if (actif != _alerteActive) {
      _alerteActive = actif;
      if (actif) {
        // Front montant : le journal raconte l'entree en alerte.
        push('Alerte trajet - $alerteCourante');
        return; // push a deja notifie les ecrans.
      }
      // Retour au calme : plus rien a dessiner.
      notifyListeners();
    } else if (actif) {
      // Deja en alerte depuis plusieurs mesures : rafraichit l'ecart affiche.
      notifyListeners();
    }
  }

  /// Vrai des que le serveur a pose au moins une affectation.
  bool get affectationRecue => base.toutesAffectations.isNotEmpty;

  /// Horodatage de la validation, affiche en badge par l'ecran DT.
  String? get horodatageAffectation =>
      base.horodatageAffectation('destination');

  /// Derniere synchro serveur terminee, a afficher par la supervision (§21).
  ///
  /// C'est l'ACK du worker qui la pose : un compteur de boucle de demo ne dit
  /// rien de l'etat du lien avec le serveur.
  DateTime? get derniereSynchro => synchro.derniereSynchro;

  final List<String> notifications = <String>[];
  final List<String> _seed = <String>[];

  Timer? _syncTimer;

  void _seedNotifications() {
    // Aucun message invente au demarrage : le ticker ne raconte que ce qui
    // arrive vraiment. Avant la premiere connexion, un seul message neutre.
    _seed.add('En attente de connexion');
    notifications.addAll(_seed);
  }

  void connect({required Profil selected, required String id, required String name}) {
    profile = selected;
    deviceId = id;
    deviceName = name;
    masterConnected = true;
    syncCount = 1;
    // L'identifiant part avec chaque evenement comme source (CDC §12).
    base.declarerAppareil(id);
    push('Connexion établie au point d\'accès Master - $name');
    startSyncLoop();
    // L'état réseau (Wi-Fi/4G) devient réel : on écoute le système au lieu
    // d'un booléen simulé.
    demarrerSurveillanceReseau();
    // La synchro serveur (§14) repart avec la session : les evenements
    // restes en PENDING au precedent demarrage sont deja relus au chargement.
    synchro.demarrer();
    notifyListeners();
  }

  void disconnect() {
    _syncTimer?.cancel();
    _syncTimer = null;
    synchro.arreter();
    arreterSurveillanceReseau();
    masterConnected = false;
    push('Deconnexion du reseau local');
    notifyListeners();
  }

  /// Boucle permanente (tache de fond) : equivalent du serveur P2P.
  void startSyncLoop() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) => _syncTick());
  }

  // ------------------------------------------------------------------ couche BLE

  /// Gateway BLE de TAB 2 : presente seulement quand le profil est excavator
  /// (TAB 2 est la passerelle, CDC §6/§7). Sinon null.
  BleGateway? _gatewayBle;

  /// Client BLE de TAB 3 : presente seulement pour le profil excavator vus
  /// du cote client... en pratique le profil excavator EST TAB 3 cote UI
  /// actuelle, mais le CDC range l'excavatrice en TAB 3. La session decide
  /// selon le profil : TAB 2 = gateway, TAB 3 = client.
  BleClient? get clientBle => _clientBle;
  BleClient? _clientBle;

  /// Etat BLE expose aux ecrans (CDC §20.2/§20.3).
  bool bleActif = false;
  int tab3Connectes = 0;
  final Map<String, int> rssiTab3 = <String, int>{};

  /// Identifiant de la passerelle (CDC §12) : TAB 2 seul.
  static const String idGateway = 'TAB2-001';

  /// Demarre la couche BLE selon le role (CDC §19 : Module TAB 2 / TAB 3).
  ///
  /// Transport injecté par l'appelant : banc pour les tests, transports
  /// réels par défaut —
  /// - TAB 3 (excavator, central) : [TransportBleCentral] (flutter_reactive_ble) ;
  /// - TAB 2 (DT, peripherique) : [TransportBlePeripherique] (ble_peripheral).
  Future<void> demarrerBle({TransportBle? transport}) async {
    final Profil? profil = profile;
    if (profil == null) return;
    // TAB 3 (excavatrice) est le client, TAB 2 le point de sortie : c'est le
    // role CDC du profil qui decide, pas son libelle.
    final bool estTab3 = profil.roleCdc == BaseLocale.roleTab3;
    final bool estTab2 = profil.roleCdc == BaseLocale.roleTab2;
    transport ??= estTab3
        ? TransportBleCentral()
        : TransportBlePeripherique();
    if (estTab3) {
      // TAB 3 (excavatrice) : client BLE vers TAB 2.
      final BleClient client = BleClient(
        transport: transport,
        sourceDevice: deviceId.isEmpty ? 'TAB3-001' : 'TAB3-$deviceId',
        role: BaseLocale.roleTab3,
      );
      client.surAck = (String eventId) {
        push('BLE ACK recu - $eventId synchronise');
        // File vidée par les ACK : la flèche retombe une fois tout acquitté.
        envoiBleActif = client.fileAttente.isNotEmpty;
        notifyListeners();
      };
      _clientBle = client;
      bleActif = true;
      final bool ok = await client.connecter();
      push(ok
          ? 'BLE connecté au DT - authentifié'
          : 'BLE : DT introuvable - données en file locale');
      // Dès que le lien BLE est vert, la file part automatiquement (CDC §16.1) :
      // la flèche d'échange s'anime pendant l'envoi et l'attente des ACK.
      if (ok) await _retransmettreFileBle();
    } else if (estTab2) {
      // TAB 2 (DT) : passerelle centrale, accepte les TAB 3 (CDC §6).
      // En transport réel, démarre l'advertising (le gateway ne le fait pas :
      // c'est le transport qui connaît la pile).
      if (transport is TransportBlePeripherique && !bleActif) {
        await transport.demarrerPublicite();
      }
      final BleGateway gateway = BleGateway(
        transport: transport,
        idsAutorises: base.idsDuRole(BaseLocale.roleTab3).toSet(),
      );
      gateway.surEvenement = (String source, Map<String, Object?> evenement) {
        // CDC §10/§11 : TAB 2 recolte, journalise et acquitte.
        base.evenementRecu(evenement);
        push('BLE evenement recu de $source : ${evenement['event_type']}');
        gateway.acquitter(source, '${evenement['event_id']}');
        notifyListeners();
      };
      _gatewayBle = gateway;
      await gateway.demarrer();
      bleActif = true;
      // Boucle de supervision RSSI (CDC §22).
      Timer.periodic(const Duration(seconds: 5), (_) async {
        await gateway.rafraichirRssi();
        tab3Connectes = gateway.clientsConnectes.length;
        rssiTab3
          ..clear()
          ..addAll(gateway.rssiClients);
        notifyListeners();
      });
      push('BLE passerelle active - ${gateway.idsAutorises.length} appareil(s) autorisé(s)');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _gatewayBle?.arreter();
    _clientBle?.arreter();
    _gatewayWifi?.arreter();
    _clientWifi?.arreter();
    servicePosition?.arreter();
    _subMesures?.cancel();
    _subMesures = null;
    alerter.fermer();
    _syncTimer?.cancel();
    synchro.arreter();
    super.dispose();
  }

  // ------------------------------------------------------------------ couche Wi-Fi

  /// Gateway Wi-Fi de TAB 2 : présent seulement pour le profil DT (TAB 2 est
  /// le point d'accès, CDC §6). Sinon null.
  WifiGateway? _gatewayWifi;

  /// Client Wi-Fi de TAB 1 : présent seulement pour le profil spotter (REQ-008).
  WifiClient? get clientWifi => _clientWifi;
  WifiClient? _clientWifi;

  /// État Wi-Fi exposé aux écrans (même pattern que [bleActif]).
  bool wifiActif = false;
  int clientsWifiConnectes = 0;

  /// Port applicatif ORE TRACKING (les deux côtés le connaissent, CDC §7).
  static const int portWifi = 45210;

  /// Démarre la couche Wi-Fi selon le rôle (CDC §19 : point d'accès TAB 2,
  /// client TAB 1). Transport injecté par l'appelant : banc en mémoire pour
  /// les tests, [TransportTcpWifi] (sockets réelles) en fonctionnement normal.
  /// Sans transport, la couche reste inactive.
  Future<void> demarrerWifi({TransportWifi? transport}) async {
    final Profil? profil = profile;
    if (profil == null) return;
    final bool estTab2 = profil.roleCdc == BaseLocale.roleTab2;
    final bool estTab1 = profil.roleCdc == BaseLocale.roleTab1;
    if (estTab2) {
      // TAB 2 : pas de transport injecté -> serveur TCP par défaut (le
      // point d'accès lui-même est activé en dehors de cette couche).
      final TransportTcpWifi tcp = transport is TransportTcpWifi
          ? transport
          : TransportTcpWifi(port: portWifi);
      await tcp.heberger();
      transport = tcp;
    }
    if (transport == null) return;
    if (estTab1) {
      // TAB 1 (spotter) : client Wi-Fi vers le point d'accès TAB 2.
      final WifiClient client = WifiClient(
        transport: transport,
        sourceDevice: deviceId.isEmpty ? 'TAB1-001' : 'TAB1-$deviceId',
        role: BaseLocale.roleTab1,
      );
      client.surAck = (String eventId) {
        push('Wi-Fi ACK reçu - $eventId transmis au DT');
        // File vidée par les ACK : la flèche retombe une fois tout acquitté.
        envoiWifiActif = client.fileAttente.isNotEmpty;
        notifyListeners();
      };
      // Reconnexion automatique (REQ-008) : à chaque retour de lien, la file
      // repart automatiquement (l'envoi initial est dans _retransmettreFileWifi).
      client.surReconnexion = _retransmettreFileWifi;
      _clientWifi = client;
      wifiActif = true;
      final bool ok = await client.connecter();
      push(ok
          ? 'Wi-Fi connecté au DT - authentifié'
          : 'Wi-Fi : DT introuvable - données en file locale');
      // Reconnexion automatique (REQ-008) : hors portée, le client retente.
      await client.demarrerReconnexionAuto();
      // Dès que le Wi-Fi devient vert, la file part automatiquement (CDC §16.1) :
      // la flèche d'échange s'anime pendant l'envoi et l'attente des ACK.
      _retransmettreFileWifi();
    } else if (estTab2) {
      // TAB 2 (DT) : point d'accès, collecte les données du spotter (REQ-007).
      final WifiGateway gateway = WifiGateway(
        transport: transport,
        idGateway: idGateway,
        idsAutorises: base.idsDuRole(BaseLocale.roleTab1).toSet(),
      );
      gateway.surEvenement = (String source, Map<String, Object?> evenement) {
        // Même traitement que le BLE : récolte, journalise, acquitte.
        base.evenementRecu(evenement);
        push('Wi-Fi données reçues de $source : ${evenement['event_type']}');
        gateway.acquitter(source, '${evenement['event_id']}');
        notifyListeners();
      };
      _gatewayWifi = gateway;
      await gateway.demarrer();
      wifiActif = true;
      push('Wi-Fi point d\'accès actif - ${gateway.idsAutorises.length} appareil(s) autorisé(s)');
    }
    notifyListeners();
  }

  /// Vrai pendant une transmission effective vers le DT (REQ-007) : la
  /// flèche d'échange ([DataExchangeButton]) s'anime tant que la file Wi-Fi
  /// contient des événements non acquittés.
  bool envoiWifiActif = false;

  /// Idem [envoiWifiActif] pour le lien BLE (TAB 3 -> TAB 2, CDC §7) : la
  /// flèche s'anime tant que la file BLE contient des non-acquittés.
  bool envoiBleActif = false;

  /// Transmet toute la file PENDING de la base au DT via le client BLE.
  /// Appelé dès que le lien BLE devient vert (authentification §9).
  Future<void> _retransmettreFileBle() async {
    final BleClient? client = _clientBle;
    if (client == null || !client.connecte) return;
    if (!base.estPersistee) return;
    envoiBleActif = true;
    notifyListeners();
    try {
      final List<Map<String, Object?>> file = await base.evenementsEnAttente();
      for (final Map<String, Object?> evenement in file) {
        await client.envoyer(evenement);
      }
    } finally {
      envoiBleActif = client.fileAttente.isNotEmpty;
      notifyListeners();
    }
  }

  /// Transmet toute la file PENDING de la base au DT via le client Wi-Fi.
  ///
  /// Appelé dès que le lien Wi-Fi devient vert (connexion/authentification,
  /// y compris après une reconnexion automatique REQ-008). La flèche reste
  /// animée tant que des événements ne sont pas acquittés (CDC §16.1).
  Future<void> _retransmettreFileWifi() async {
    final WifiClient? client = _clientWifi;
    if (client == null || !client.connecte) return;
    if (!base.estPersistee) return;
    envoiWifiActif = true;
    notifyListeners();
    try {
      final List<Map<String, Object?>> file = await base.evenementsEnAttente();
      for (final Map<String, Object?> evenement in file) {
        await client.envoyer(evenement);
      }
    } finally {
      envoiWifiActif = client.fileAttente.isNotEmpty;
      notifyListeners();
    }
  }

  void _syncTick() {
    syncCount++;
    // La boucle de fond ne simule plus rien : les positions viennent du GPS
    // reel (ServicePosition), la synchro serveur du worker (Synchronisation)
    // qui pousse ses propres messages. L'avancement du trajet reste gere ici
    // (territore de l'ecran DT).
    if (routeProgress < 0.95) {
      routeProgress = min(0.95, routeProgress + 0.03);
    }
    notifyListeners();
  }

  void push(String message) {
    notifications
      ..removeWhere((m) => m == message)
      ..add(message);
    if (notifications.length > 12) {
      notifications.removeRange(0, notifications.length - 12);
    }
    notifyListeners();
  }
}
