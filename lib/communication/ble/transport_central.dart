import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart' as rble;

import 'transport_ble.dart';
import 'transport_peripherique.dart';

/// Transport BLE réel côté TAB 3 (central) : `flutter_reactive_ble`.
///
/// Implémente [TransportBle] : scan (discovery du service ORE TRACKING),
/// connexion GATT, envois par écriture de caractéristique, réception par
/// notifications. La logique du [BleClient] au-dessus ne change pas.
class TransportBleCentral implements TransportBle {
  TransportBleCentral({
    this.serviceUuid = TransportBlePeripherique.uuidService,
    this.caracteristiqueRx = TransportBlePeripherique.uuidCaracteristiqueRx,
    this.caracteristiqueTx = TransportBlePeripherique.uuidCaracteristiqueTx,
    rble.FlutterReactiveBle? pile,
  }) : _pile = pile ?? rble.FlutterReactiveBle();

  final String serviceUuid;
  final String caracteristiqueRx;
  final String caracteristiqueTx;

  final rble.FlutterReactiveBle _pile;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  @override
  Stream<bool> get etatPile => _pile.statusStream
      .map((rble.BleStatus s) => s == rble.BleStatus.ready)
      .asBroadcastStream();

  /// Decouverte des excavatrices.
  ///
  /// CRITERE : le SERVICE GATT, plus jamais le nom (refonte du 27/10).
  ///
  /// Pourquoi ce changement. Le scan filtrait sur `d.name.startsWith('ORE-EXC')`.
  /// Or `localName` n'est PAS fiable dans un advertisement BLE : le paquet
  /// fait 31 octets au total, le fabricant peut le tronquer a 8-10 octets, et
  /// certains adaptateurs l'omettent purement et simplement. Consequence
  /// constatee : `ORE-EXC-EX-2000` arrivait en `ORE-EXC-…` (ou vide), la
  /// comparaison echouait, AUCUN appareil n'etait retenu — et **aucune
  /// connexion GATT n'etait meme tentee** (journaux vides de toute tentative).
  ///
  /// Un UUID de service fait 16 octets FIXES : il ne peut etre ni tronque ni
  /// omis quand le peripherique l'annonce, et c'est justement lui que
  /// `startAdvertising(services: [uuidService])` declare.
  ///
  /// Deux passes, dans cet ordre :
  ///   1. filtre sur le service (rapide, sans bruit) ;
  ///   2. si rien n'est vu, scan large ou l'on retient tout appareil qui
  ///      annonce notre service OU dont le nom commence par `ORE-EXC` —
  ///      filet pour les piles qui ne remontent pas `serviceData` au scan.
  /// Le nom ne sert plus qu'a l'AFFICHAGE.
  @override
  Stream<AppareilBle> scanner() async* {
    // SCAN A DUREE BORNEE + LIBERATION EXPLICITE (fix critique 30/10).
    //
    // `scanForDevices()` rend un stream INFINI : tant qu'il est ecoute, le
    // controller de scan Android reste actif. Or lancer `connectToDevice()`
    // pendant un scan actif fait echouer le GATT immediatement sur Android 12+
    // (« Bad state: connexion BLE perdue » < 1 s, constate en terrain).
    // Le `await for` de l'appelant s'arrete au `break`, mais l'abonnement au
    // stream natif, lui, ne se liberait pas tout de suite.
    //
    // On borne donc la duree du scan et on annule l'abonnement AVANT de rendre
    // la main, pour que la pile soit libre au moment de la connexion.
    final StreamSubscription<rble.DiscoveredDevice> sub =
        _pile.scanForDevices(withServices: const <rble.Uuid>[]).listen(null);
    try {
      // Scan sans filtre `withServices` : sur Android 15 (Active 7), le filtre
      // materiel rate l'excavatrice de facon intermittente. Le scan ouvert la
      // voit a 100 % (nom 'ORE-EXC-001' a -28/-35 dBm).
      await for (final rble.DiscoveredDevice d in _pile.scanForDevices(
        withServices: const <rble.Uuid>[],
      )) {
        // FILTRE SUR LE SERVICE, PLUS SUR LE NOM (fix 30/10).
        //
        // Le `localName` n'est pas garanti dans un advertisement BLE : le
        // paquet fait 31 octets, le fabricant peut le tronquer ou l'omettre.
        // Un RSSI de -53 dBm avec un appareil introuvable signale exactement
        // ce cas. L'UUID de service, lui, fait 16 octets fixes et ne peut pas
        // etre omis quand le peripherique l'annonce.
        //
        // Le nom ne sert plus qu'a l'AFFICHAGE ; on le garde en repli si la
        // pile ne remonte pas les UUID de service.
        final rble.Uuid uuidService = rble.Uuid.parse(serviceUuid);
        final bool serviceOre = d.serviceData.containsKey(uuidService) ||
            d.serviceUuids.contains(uuidService);
        final bool nomOre = d.name.startsWith('ORE-EXC');
        if (!serviceOre && !nomOre) continue;
        yield AppareilBle(
          id: d.id,
          nom: d.name.isEmpty ? 'ORE-EXC' : d.name,
          rssi: d.rssi,
          serviceOre: serviceOre,
        );
      }
    } finally {
      // Quoi qu'il arrive (break de l'appelant, timeout, erreur) : on coupe
      // le scan natif avant de laisser la main a la connexion GATT.
      await sub.cancel();
    }
  }

  /// Connexion GATT AVEC RELANCE INTERNE (fix 30/10).
  ///
  /// Symptôme : après une réactivation du Bluetooth (ou un rebond), la pile
  /// ouvre le lien GATT puis le referme immédiatement (« connexion BLE
  /// perdue ») — l'excavatrice n'a pas encore son serveur GATT prêt quand le
  /// client tente de s'accrocher, ou le cache services/MTU du côté Android
  /// est sale après la reprise de la pile. La boucle de reconnexion du
  /// BleClient rétait effectivement sa prochaine tentative, mais chaque
  /// tentative réouvrait-fermait : aucun progrès possible.
  ///
  /// La connexion reste donc ici jusqu'à STABILITÉ : si une déconnexion
  /// survient avant l'armement du lien (MTU + découverte + souscription
  /// caractéristique), la demande de connexion est relancée après un petit
  /// délai — c'est un autoConnect applicatif, sans appairage OS ni boucle
  /// d'erreur côté appelant. L'appelant (BleClient) garde son comportement :
  /// `connecter()` ne rend la main que sur un lien PRÊT, sinon exception.
  @override
  Future<LienBle> connecter(AppareilBle appareil) async {
    const Duration entreTentatives = Duration(milliseconds: 800);
    const int maxTentatives = 5;

    for (int tentative = 1; tentative <= maxTentatives; tentative++) {
      final Completer<void> pret = Completer<void>();
      final Completer<void> cassee = Completer<void>();
      late final StreamSubscription<rble.ConnectionStateUpdate> sub;
      sub = _pile
          .connectToDevice(
            id: appareil.id,
            connectionTimeout: const Duration(seconds: 10),
          )
          .listen(
            (rble.ConnectionStateUpdate u) {
              if (u.connectionState ==
                      rble.DeviceConnectionState.connected &&
                  !pret.isCompleted) {
                pret.complete();
              } else if (u.connectionState ==
                      rble.DeviceConnectionState.disconnected) {
                // Connecté puis déconnecté avant armement : lien instable,
                // on marie la casse pour relancer (voir ci-dessus).
                if (!pret.isCompleted) {
                  pret.completeError(StateError('connexion BLE perdue'));
                } else if (!cassee.isCompleted) {
                  cassee.complete();
                }
              }
            },
            onError: (Object e) {
              if (!pret.isCompleted) pret.completeError(e);
            },
          );
      _subs.add(sub);

      try {
        await pret.future;
      } catch (_) {
        await sub.cancel();
        _subs.remove(sub);
        // Dernière tentative : on laisse l'erreur remonter à BleClient
        // (qui journalise et reprogrammera sa boucle).
        if (tentative == maxTentatives) rethrow;
        await Future<void>.delayed(entreTentatives);
        continue;
      }

      // LIEN CONNECTE — armement complet. Toute casse avant la fin est
      // considérée comme « pile pas prête » : relance.
      try {
        // MTU maximal : les messages JSON §12 doivent passer en une écriture.
        try {
          await _pile.requestMtu(deviceId: appareil.id, mtu: 512).timeout(
                const Duration(seconds: 4),
                onTimeout: () => throw TimeoutException('mtu'),
              );
        } catch (_) {
          // Refus possible : les messages restent bornés par BleProtocole.
        }

        // Découverte des services AVANT toute souscription GATT : sans elle,
        // `subscribeToCharacteristic` échoue (service inconnu du cache) et
        // la fermeture immédiate du lien suit — observé en terrain sur
        // Android 15 ("Bad state: lien ferme" juste après la connexion).
        try {
          await _pile.getDiscoveredServices(appareil.id);
        } catch (_) {
          // Échec non bloquant : la souscription tentera sa propre découverte.
        }

        // Décantation Link-Layer (recommandation conseil LLM : 300 ms) :
        // laisse le stack BLE Android enregistrer la découverte et le CCCD
        // avant que le premier write/subscribe ne parte.
        await Future<void>.delayed(const Duration(milliseconds: 300));

        final LienCentral lien = LienCentral._(this, appareil.id);
        // Le lien souscrit déjà sa caractéristique dans son constructeur :
        // si la connexion a cassé pendant cet armement, le stream des
        // messages est déjà fermé — détecté ici, traité comme instable.
        if (!lien.ouvert) {
          throw StateError('lien ferme pendant armement');
        }
        return lien;
      } catch (_) {
        // On referme tout proprement avant de relancer.
        try {
          // reactive_ble n'expose pas de deconnexion directe : la fermeture de la
          // souscription suffit a lacher le lien.
          await sub.cancel();
        } catch (_) {
          // La pile l'a déjà fait.
        }
        await sub.cancel();
        _subs.remove(sub);
        if (tentative == maxTentatives) rethrow;
        await Future<void>.delayed(entreTentatives);
        continue;
      }
    }
    // Inatteignable (le for retourne ou rethrow), garde-fou pour l'analyseur.
    throw StateError('connexion BLE impossible : tentatives epuisees');
  }

  @override
  Stream<LienBle> liensEntrants() =>
      throw UnsupportedError('le central ne sert que de client');

  @override
  Future<void> arreter() async {
    for (final StreamSubscription<Object?> s in List.of(_subs)) {
      await s.cancel();
    }
    _subs.clear();
  }
}

/// Lien GATT côté TAB 3 (central), vu par le BleClient comme un [LienBle].
class LienCentral implements LienBle {
  LienCentral._(this._transport, this._deviceId) {
    _souscrire();
  }

  /// Souscrit UNE SEULE FOIS aux notifications de la caracteristique TX.
  ///
  /// CAUSE RACINE DEFINITIVE (30/10, logs natifs) :
  ///
  /// Le DT ouvrait 4 connexions GATT vers la meme adresse
  /// (`Connected client_if:3 / 4 / 5 / 7 → GATT_CONN_OK`). Android limite les
  /// clients GATT simultanes d'un meme appareil (~4) ; au-dela, le serveur ne
  /// trouve plus de callback pour les `conn_id` surnumeraires :
  ///   `W gatt_utils: Call back not found for application conn_id=3/4/5`
  /// puis il traite le client comme non fiable et coupe :
  ///   `remove untrusted client status` + `GATT_CONN_TERMINATE_PEER_USER`.
  ///
  /// Ces connexions multiples venaient de la re-souscription en boucle sur
  /// `onDone`. On ne re-souscrit plus JAMAIS : un seul abonnement, ouvert a la
  /// construction du lien.
  ///
  /// `onDone`/`onError` signifient ici que le canal de notification s'est
  /// ferme. Le lien GATT, lui, est surveille par la couche au-dessus
  /// (watchdog + reconnexion) : c'est elle qui doit decider de rouvrir une
  /// session, pas une souscription qui consommerait un slot GATT de plus.
  void _souscrire() {
    _subMessages = _transport._pile
        .subscribeToCharacteristic(
          rble.QualifiedCharacteristic(
            characteristicId: rble.Uuid.parse(_transport.caracteristiqueTx),
            serviceId: rble.Uuid.parse(_transport.serviceUuid),
            deviceId: _deviceId,
          ),
        )
        .listen(
          (List<int> octets) {
            if (_ouvert) _reception.add(Uint8List.fromList(octets));
          },
          onError: (Object e) {
            debugPrint('LienCentral onError (notifications) : \$e');
            // On NE ferme PAS le lien et on ne re-souscrit PAS : le slot GATT
            // est unique. La couche au-dessus gerera la reconnexion.
          },
          onDone: () {
            debugPrint('LienCentral onDone (notifications terminees)');
            // Idem : pas de re-souscription (voir ci-dessus).
          },
        );
  }

  final TransportBleCentral _transport;
  final String _deviceId;
  late final StreamSubscription<List<int>> _subMessages;
  final StreamController<Uint8List> _reception =
      StreamController<Uint8List>.broadcast();
  bool _ouvert = true;

  /// RSSI mesuré sur le lien central : le peripherique Android ne peut pas
  /// le lire, le client le déclare donc dans son handshake (CDC §8).
  int? rssiMesure;

  @override
  String get idPair => _deviceId;

  @override
  bool get ouvert => _ouvert;

  @override
  Stream<Uint8List> get messages => _reception.stream;

  /// Mesure le RSSI du lien (API centrale de la pile).
  @override
  Future<int?> mesurerRssi() async {
    try {
      rssiMesure = await _transport._pile.readRssi(_deviceId);
      return rssiMesure;
    } catch (_) {
      return rssiMesure;
    }
  }

  @override
  Future<void> envoyer(Uint8List octets) async {
    if (!_ouvert) throw StateError('lien ferme');
    await _transport._pile.writeCharacteristicWithoutResponse(
      rble.QualifiedCharacteristic(
        characteristicId: rble.Uuid.parse(_transport.caracteristiqueRx),
        serviceId: rble.Uuid.parse(_transport.serviceUuid),
        deviceId: _deviceId,
      ),
      value: octets,
    );
  }

  @override
  Future<void> fermer() async => _fermer();

  void _fermer() {
    if (!_ouvert) return;
    _ouvert = false;

    // FERMETURE SANS CRASH (fix 30/10, crash RxBleThread).
    //
    // flutter_reactive_ble emet ses erreurs GATT sur son propre thread RxJava.
    // Si on annule la souscription pendant qu'une erreur est en vol, la
    // librairie ne peut plus la livrer et leve une exception FATALE :
    //   "The exception could not be delivered to the consumer because it has
    //    already canceled/disposed the flow"
    // -> crash de l'app entiere (observe en terrain, status 22
    // GATT_CONN_TERMINATE_LOCAL_HOST).
    //
    // On annule donc APRES un tour de boucle, en absorbant toute erreur, et
    // on laisse le flux ouvert le temps que l'erreur soit consommee.
    Future<void>.delayed(const Duration(milliseconds: 150), () {
      try {
        _subMessages.cancel();
      } catch (_) {
        // flux deja termine : rien a annuler.
      }
    });

    if (!_reception.isClosed) _reception.close();
  }
}
