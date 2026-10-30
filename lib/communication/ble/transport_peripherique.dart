import 'dart:async';
import 'dart:io';
import 'package:ble_peripheral/ble_peripheral.dart' as periph;
import 'package:flutter/foundation.dart';

import 'transport_ble.dart';

/// Transport BLE réel côté TAB 2 (peripherique / GATT server).
///
/// `flutter_reactive_ble` n'opère qu'en central : le role peripherique vient
/// du plugin `ble_peripheral` ([periph.BlePeripheral]), derriere la meme
/// interface [TransportBle] que le banc — la logique du gateway n'y change
/// rien (CDC §29).
///
/// Architecture GATT :
/// - un service ORE TRACKING primaire ;
/// - une caracteristique RX (le TAB 3 y ecrit ses messages) ;
/// - une caracteristique TX (TAB 2 notifie ses reponses : ACK, HANDSHAKE_*).
///
/// Limites connues du role peripherique :
/// - le RSSI natif n'est pas expose par Android sur un lien GATT server :
  /// le client mesure et declare son RSSI dans le handshake (champ `rssi`),
  /// que [LienPeripherique.mesurerRssi] renvoie en priorite ;
/// - l'identification du client (idPair) est l'adresse MAC fournie par la
///   pile Android, que le handshake complete par l'id applicatif.
class TransportBlePeripherique implements TransportBle {
  TransportBlePeripherique({
    // Nom d'advertising FIXE et STANDARD : 'ORE-EXC-001'.
    //
    // Constat du 27/10 : personnaliser ce nom ('ORE-EXC-HYUNDAI-32') cassait
    // l'advertising sur Android (nom trop long dans le paquet de 31 octets,
    // rejete ou tronque par la pile) et le scan des DT ne trouvait plus rien.
    // L'identite REELLE de l'engin (ex. HYUNDAI-32) voyage dans le HANDSHAKE
    // applicatif (`source_device`), pas dans le nom radio.
    this.nomPublic = 'ORE-EXC-001',
    this.identiteEnrolee = '',
    this.codeRole = 3,
    this.serviceUuid = uuidService,
    this.caracteristiqueRx = uuidCaracteristiqueRx,
    this.caracteristiqueTx = uuidCaracteristiqueTx,
  });

  /// Nom d'advertising fixe annonce par toute excavatrice.
  static String nomAdvertise(String _) => 'ORE-EXC-001';

  /// UUID du service ORE TRACKING (arbitraire mais fixe : les deux côtés
  /// doivent convenir des mêmes).
  static const String uuidService =
      '0000fe5a-0000-1000-8000-00805f9b34fb';
  static const String uuidCaracteristiqueRx =
      '0000fe5b-0000-1000-8000-00805f9b34fb';
  static const String uuidCaracteristiqueTx =
      '0000fe5c-0000-1000-8000-00805f9b34fb';

  /// Nom annoncé en advertising : les clients BLE (DT) cherchent un nom qui
  /// commence par `ORE-EXC` (BleClient.connecter).
  final String nomPublic;

  /// Identite enrolee publiee dans le scan response (ex. 'EX-32').
  /// Vide = l'app ne publie que le role, sans id.
  final String identiteEnrolee;

  /// Code du role : 1 = Spotter, 2 = DT, 3 = Excavatrice.
  final int codeRole;
  final String serviceUuid;
  final String caracteristiqueRx;
  final String caracteristiqueTx;

  final StreamController<LienBle> _entrants =
      StreamController<LienBle>.broadcast();
  /// Flux de l'etat de l'ADAPTATEUR Bluetooth local (vrai = allume).
  final StreamController<bool> _pile = StreamController<bool>.broadcast();
  Timer? _surveillePile;
  bool _surveillanceArmee = false;
  bool _dernierEtatPile = true;

  /// Vrai des que [demarrerPublicite] a ete demandee et tant que
  /// [arreterPublicite] ne l'a pas annulee : c'est ce que le chien de garde
  /// compare a la realite de la pile.
  bool _publiciteVoulue = false;
  final Map<String, LienPeripherique> _liens =
      <String, LienPeripherique>{};
  bool _prete = false;

  @override
  Stream<bool> get etatPile {
    _demarrerSurveillancePile();
    return _pile.stream;
  }

  /// Surveille l'adaptateur Bluetooth, et separement notre publicite.
  ///
  /// POURQUOI CETTE REECRITURE (29/10). La version precedente sondait
  /// `BlePeripheral.isAdvertising()` et prenait sa reponse pour l'etat de la
  /// pile. Or ce getter ne lit pas l'adaptateur : cote Android il renvoie un
  /// simple drapeau que le plugin met a vrai au demarrage de la publicite et
  /// a faux a son arret. La boucle se mordait donc la queue — la publicite
  /// n'etait relancee qu'a la transition `false -> true`, transition que
  /// SEULE une publicite deja en cours pouvait produire. Une fois
  /// l'advertising tombe (coupure du Bluetooth, reinstallation de l'APK),
  /// plus rien ne le relevait : l'excavatrice affichait « BLE actif, aucun
  /// DT » et restait muette pendant que le DT scannait dans le vide.
  ///
  /// Deux mecanismes distincts, parce que ce sont deux pannes distinctes :
  /// - `setBleStateChangeCallback`, alimente par le `BroadcastReceiver`
  ///   `ACTION_STATE_CHANGED` du plugin, donne le VRAI etat de l'adaptateur ;
  /// - un chien de garde verifie que notre publicite tourne encore, car
  ///   Android peut l'arreter sans que l'adaptateur bouge.
  void _demarrerSurveillancePile() {
    if (_surveillanceArmee) return;
    // Pas de chien de garde dans les tests : un Timer.periodic non annule fait
    // echouer le framework (!timersPending). C'est un mecanisme de terrain.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    _surveillanceArmee = true;
    periph.BlePeripheral.setBleStateChangeCallback(_surEtatAdaptateur);
    _surveillePile = Timer.periodic(const Duration(seconds: 10), (_) async {
      // Rien a surveiller tant que personne n'a demande la publicite.
      if (!_publiciteVoulue || !_dernierEtatPile) return;
      bool annonce;
      try {
        annonce = await periph.BlePeripheral.isAdvertising() ?? false;
      } catch (_) {
        annonce = false;
      }
      if (annonce) return;
      // Publicite morte alors que l'adaptateur est allume : c'est l'etat
      // « zombie » observe apres une reinstallation de l'APK. On la relance
      // ici au lieu d'attendre un redemarrage de la tablette.
      debugPrint('OREBLE publicite arretee sans coupure BT - relance');
      try {
        await demarrerPublicite();
      } catch (e) {
        debugPrint('OREBLE relance de la publicite impossible : $e');
      }
    });
  }

  /// L'adaptateur Bluetooth vient de changer d'etat.
  void _surEtatAdaptateur(bool active) {
    if (active == _dernierEtatPile) return;
    _dernierEtatPile = active;
    if (!active) {
      // Android DETRUIT le GATT server a l'extinction du Bluetooth : le
      // service, ses caracteristiques et les liens ouverts n'existent plus.
      // On l'oublie pour que `preparer()` reconstruise tout au retour. Sans
      // cet oubli, `preparer()` sortait sur `_prete` et la publicite
      // repartait au-dessus d'un serveur GATT vide : les DT voyaient bien
      // l'annonce mais aucune connexion n'aboutissait.
      _prete = false;
      for (final String id in List<String>.of(_liens.keys)) {
        _fermerLien(id);
      }
    }
    debugPrint('OREBLE adaptateur ${active ? 'allume' : 'eteint'}');
    _pile.add(active);
  }

  /// Prépare le GATT server : service + caractéristiques, callbacks. A
  /// appeler une fois avant [demarrerPublicite].
  Future<void> preparer() async {
    if (_prete) return;
    // `initialize()` rouvre le GATT server. On la rappelle a chaque
    // reconstruction (apres une coupure du Bluetooth, `_prete` est remis a
    // faux par [_surEtatAdaptateur]) : c'est la seule facon de retrouver un
    // serveur vivant, le plugin ne le rouvrant jamais de lui-meme.
    periph.BlePeripheral.setWriteRequestCallback(
      (
        String deviceId,
        String characteristicId,
        int offset,
        Uint8List? valeur,
      ) {
        debugPrint('OREBLE rx ${valeur?.length} octets sur '
            '$characteristicId de $deviceId');
        // Le plugin renvoie l'UUID en majuscules (`0000FE5B-...`) alors que
        // les constantes sont en minuscules : comparer sans la casse, sinon
        // l'ecriture du client est jetee et le gateway repond "pas de
        // handshake" (observe en terrain, 21/10).
        if (valeur == null ||
            characteristicId.toLowerCase() != caracteristiqueRx) {
          return null;
        }
        _livrer(deviceId, valeur);
        // Accusé GATT : écriture acceptée.
        return periph.WriteRequestResult(status: 0);
      },
    );
    periph.BlePeripheral.setConnectionStateChangeCallback(
      (String deviceId, bool connecte) {
        if (!connecte) _fermerLien(deviceId);
      },
    );
    periph.BlePeripheral.setServiceAddedCallback(
        (String serviceId, String? erreur) {
      // Journalise, ne leve pas : une exception depuis un callback de plugin
      // ne remonte a personne et fait seulement tomber le gestionnaire.
      if (erreur != null) {
        debugPrint('OREBLE service GATT refuse : $erreur');
      }
    });
    // PAS de `clearServices()` ici.
    //
    // `initialize()` vient d'ouvrir un serveur GATT NEUF, donc vide : il n'y
    // a rien a nettoyer. Et surtout, `addService` est ASYNCHRONE cote Android
    // (le plugin rend la main aussitot, la confirmation arrive par
    // `onServiceAdded`) : enchainer un nettoyage et un ajout les fait courir
    // l'un contre l'autre, et le service peut etre efface apres avoir ete
    // ajoute. Le serveur reste alors sans service pendant que la publicite
    // continue d'annoncer l'UUID — le DT voit l'excavatrice, s'y connecte et
    // n'obtient jamais de reponse.
    // Ouverture du serveur APRES avoir pose tous les callbacks (fix 30/10).
    await periph.BlePeripheral.initialize();

    await periph.BlePeripheral.addService(
      periph.BleService(
        uuid: serviceUuid,
        primary: true,
        characteristics: <periph.BleCharacteristic>[
          // RX : le client écrit ici (write sans réponse, pour ne pas
          // bloquer sur l'attente d'un accusé GATT).
          periph.BleCharacteristic(
            uuid: caracteristiqueRx,
            properties: <int>[
              periph.CharacteristicProperties.writeWithoutResponse.index,
              periph.CharacteristicProperties.write.index,
            ],
            permissions: <int>[
              periph.AttributePermissions.writeable.index,
            ],
          ),
          // TX : TAB 2 notifie ici (ACK, verdicts de handshake).
          periph.BleCharacteristic(
            uuid: caracteristiqueTx,
            properties: <int>[
              periph.CharacteristicProperties.read.index,
              periph.CharacteristicProperties.notify.index,
            ],
            permissions: <int>[
              periph.AttributePermissions.readable.index,
            ],
          ),
        ],
      ),
    );

    // (deplace avant initialize() ci-dessus)
    // CE QUE LE SERVEUR PORTE REELLEMENT.
    //
    // L'advertisement annonce l'UUID du service parce qu'on le lui passe en
    // parametre, pas parce que le service existe : les deux sont
    // independants. Sans cette trace, un serveur vide est indiscernable d'un
    // serveur correct vu du journal — c'est precisement ce qui a coute une
    // soiree de diagnostic (29/10).
    try {
      final List<String> services = await periph.BlePeripheral.getServices();
      debugPrint('OREBLE services GATT enregistres : '
          '${services.isEmpty ? 'AUCUN' : services.join(', ')}');
    } catch (e) {
      debugPrint('OREBLE impossible de lire les services GATT : $e');
    }
    _prete = true;
  }

  /// Démarre l'advertising : c'est ce qui rend TAB 2 visible des TAB 3.
  Future<void> demarrerPublicite() async {
    _publiciteVoulue = true;
    await preparer();
    // Le paquet BLE legacy (1M PHY) est strictement limite a 31 octets.
    // L'UUID 128 bits prend deja 18 octets (1 len + 1 type + 16 data),
    // les flags prennent 3 octets -> il ne reste que 10 octets !
    // Si on ajoute des manufacturerData en plus, le paquet depasse 31 octets
    // et Android renvoie ADVERTISE_FAILED_DATA_TOO_LARGE en silence.
    // On ne met donc QUE le serviceUuid et le localName : c'est ce qui
    // garantit que l'advertising demarre toujours sans erreur.
    await periph.BlePeripheral.startAdvertising(
      services: <String>[serviceUuid],
      localName: nomPublic,
    );
  }

  Future<void> arreterPublicite() {
    _publiciteVoulue = false;
    return periph.BlePeripheral.stopAdvertising();
  }

  void _livrer(String deviceId, Uint8List octets) {
    // Un message du client crée le lien s'il n'existe pas encore : le
    // gateway s'abonne à `liensEntrants()` puis à `lien.messages` — avec un
    // délai de quelques microtâches entre les deux. Le premier message (le
    // handshake) peut donc arriver PENDANT ce délai : ajouté à un stream
    // broadcast sans rétention, il était perdu et le gateway répondait
    // « pas de handshake » (observé en terrain : 92 octets reçus par le
    // callback natif, jamais livrés au gateway).
    final LienPeripherique lien = _liens.putIfAbsent(
      deviceId,
      () {
        final LienPeripherique l = LienPeripherique._(
          this,
          deviceId,
        );
        _entrants.add(l);
        return l;
      },
    );
    lien._recevoir(octets);
  }

  void _fermerLien(String deviceId) {
    _liens.remove(deviceId)?._fermer();
  }

  Future<void> _notifier(LienPeripherique lien, Uint8List octets) =>
      periph.BlePeripheral.updateCharacteristic(
        characteristicId: caracteristiqueTx,
        value: octets,
        deviceId: lien.idPair,
      );

  // Non utilisé côté gateway : TAB 2 n'initie pas de connexion ni de scan.
  @override
  Stream<AppareilBle> scanner() =>
      throw UnsupportedError('le peripherique ne scanne pas');

  @override
  Future<LienBle> connecter(AppareilBle appareil) async =>
      throw UnsupportedError("le peripherique n'initie pas de connexion");

  @override
  Stream<LienBle> liensEntrants() => _entrants.stream;

  @override
  Future<void> arreter() async {
    _surveillePile?.cancel();
    _surveillePile = null;
    _surveillanceArmee = false;
    await arreterPublicite();
    for (final String id in List<String>.of(_liens.keys)) {
      _fermerLien(id);
    }
    await _entrants.close();
  }
}

/// Lien GATT côté TAB 2, vu par le gateway comme un [LienBle] ordinaire.
class LienPeripherique implements LienBle, LienDeclaratif {
  LienPeripherique._(this._transport, this._deviceId) {
    // Au premier listen (le gateway, quelques microtaches apres la creation
    // du lien), on rejoue ce qui est arrive entre-temps : sans cela le
    // handshake envoye immediatement apres la connexion etait perdu (stream
    // broadcast = aucune retention).
    _reception = StreamController<Uint8List>.broadcast(
      onListen: () {
        if (_enAttente.isEmpty) return;
        final List<Uint8List> aRejouer = List<Uint8List>.of(_enAttente);
        _enAttente.clear();
        for (final Uint8List o in aRejouer) {
          _reception.add(o);
        }
      },
    );
  }

  final TransportBlePeripherique _transport;
  final String _deviceId;
  late final StreamController<Uint8List> _reception;
  bool _ouvert = true;

  /// RSSI déclaré par le client dans son handshake (null tant qu'il n'a pas
  /// parlé) : Android ne l'expose pas côté peripherique.
  @override
  int? rssiDeclare;

  @override
  String get idPair => _deviceId;

  @override
  bool get ouvert => _ouvert;

  @override
  Stream<Uint8List> get messages => _reception.stream;

  @override
  Future<int?> mesurerRssi() async => rssiDeclare;

  @override
  Future<void> envoyer(Uint8List octets) async {
    if (!_ouvert) throw StateError('lien ferme');
    await _transport._notifier(this, octets);
  }

  @override
  Future<void> fermer() async => _fermer();

  void _fermer() {
    if (!_ouvert) return;
    _ouvert = false;
    _reception.close();
  }

  void _recevoir(Uint8List octets) {
    if (!_ouvert) return;
    // Rétention : tant que personne n'écoute (le gateway s'abonne à
    // `liensEntrants` PUIS à `messages`, avec un délai entre les deux), le
    // message est mis en attente au lieu d'être perdu. Un stream broadcast
    // ne garde rien ; le handshake envoyé immédiatement après la connexion
    // arrivait donc sur un flux sans auditeur.
    if (!_reception.hasListener) {
      _enAttente.add(octets);
      return;
    }
    _reception.add(octets);
  }

  /// Messages recus avant tout abonnement (course
  /// `_livrer`/`_accueilLien`), rejoués au premier listen.
  final List<Uint8List> _enAttente = <Uint8List>[];
}
