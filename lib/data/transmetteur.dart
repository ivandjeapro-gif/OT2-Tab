import 'dart:convert';

import 'package:http/http.dart' as http;

/// Enveloppe d'un evenement, telle que le CDC §12 la decrit.
///
/// Les champs viennent des colonnes de `evenements` : rien n'est invente au
/// moment de l'envoi, ce qui rend la file autonome et rejouable a l'identique.
class Enveloppe {
  const Enveloppe({
    required this.eventId,
    required this.gatewayId,
    required this.sourceDevice,
    required this.eventType,
    required this.timestamp,
    required this.payload,
  });

  /// Identifiant unique (REQ-014) : c'est aussi la cle d'idempotence.
  final String eventId;

  /// Passerelle qui relaie (§12).
  final String gatewayId;

  /// Appareil a l'origine de l'evenement (§12).
  final String sourceDevice;

  /// Nature de l'evenement : LINE_ADD, BLAST_LOCK, BLAST_SEND, ...
  final String eventType;

  /// Horodatage ISO 8601 UTC conserve a l'ecriture (§12).
  final String timestamp;

  /// Contenu metier. Stocke en texte dans la base, repasse en objet ici :
  /// c'est ainsi que le serveur le recoit.
  final Object payload;

  /// Construite depuis une ligne de la table `evenements`.
  factory Enveloppe.depuisLigne(Map<String, Object?> ligne) {
    final Object brut = ligne['payload'] ?? '';
    Object contenu;
    try {
      contenu = jsonDecode(brut as String);
    } catch (_) {
      // Un payload illisible ne doit pas bloquer la file : on l'envoie tel
      // quel, c'est au serveur de rejeter proprement (422).
      contenu = <String, Object?>{'brut': '$brut'};
    }
    return Enveloppe(
      eventId: ligne['event_id']! as String,
      gatewayId: (ligne['gateway_id'] as String?) ?? '',
      sourceDevice: ligne['source_device']! as String,
      eventType: ligne['event_type']! as String,
      timestamp: ligne['timestamp']! as String,
      payload: contenu,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'event_id': eventId,
        'gateway_id': gatewayId,
        'source_device': sourceDevice,
        'event_type': eventType,
        'timestamp': timestamp,
        'payload': payload,
      };

  @override
  String toString() => jsonEncode(toJson());
}

/// Reponse du serveur, qu'elle vienne du reseau ou d'un timeout.
class ReponseServeur {
  const ReponseServeur({required this.code, this.erreur});

  /// 0 = aucun octet recu : reseau absent, timeout, hote inconnu.
  final int code;

  /// Motif lisible, pour le journal (§22).
  final String? erreur;

  /// 2xx : accusé de reception (§14).
  bool get ok => code >= 200 && code < 300;

  /// 409 : deja recu. Idempotent (REQ-015), donc traite comme un succes.
  bool get doublon => code == 409;

  /// Ce qui fait sortir l'evenement de la file PENDING.
  bool get accepte => ok || doublon;
}

/// Affectation courante, choisie **et validee par le serveur**.
///
/// Le client ne la modifie jamais : il la recoit, l'affiche et la conserve
/// jusqu'a la suivante. `champs` porte les paires cle/valeur (`destination`,
/// `dumping_area`, `mission`, ...), `valideLe` l'instant ou le serveur a
/// valide cette affectation (celui que l'ecran affiche en badge).
class Affectation {
  const Affectation({required this.champs, this.valideLe});

  final Map<String, String> champs;
  final String? valideLe;

  String? valeur(String cle) => champs[cle];
}

/// Ce qui sait parler au serveur.
///
/// Injecte au worker : l'application fournit l'implantation HTTP, les tests un
/// double scriptable. Aucun appel reseau n'est possible sans passer par la.
abstract class Transmetteur {
  /// Pousse un evenement vers `{api_base}/evenements` (§14).
  Future<ReponseServeur> envoyer(Enveloppe enveloppe);

  /// Lit l'affectation courante : `{api_base}/affectation` (contrat §8).
  ///
  /// `null` = rien a changer (404, erreur serveur, reseau absent) : le
  /// conservateur garde la derniere valeur connue. Une reponse 200 sans
  /// aucun champ rend egalement `null`.
  Future<Affectation?> lireAffectation();

  /// Dernier retour reseau observe : `true` = le serveur a repondu,
  /// `false` = aucune reponse (reseau absent, timeout, hote inconnu),
  /// `null` = rien n'a encore ete tente.
  ///
  /// C'est la source du badge 4G (§21) : « connecte » signifie « quelqu'un
  /// a repondu de l'autre cote », pas « la file est vide ». Les doubles de
  /// test n'ont pas a l'implementer.
  bool? get serveurRepondu => null;
}

/// Transmetteur reel : POST JSON vers `{api_base}/evenements` (§14).
///
/// L'URL et le jeton sont lus dans `meta` a chaque envoi : les changer ne
/// demande aucun redemarrage. Toute anomalie (hote absent, timeout, certificat)
/// est rendue en `code = 0`, jamais en exception — c'est au worker de decider
/// de rejouer.
class TransmetteurHttp implements Transmetteur {
  TransmetteurHttp({
    required String? Function(String cle) meta,
    http.Client? client,
    this.delai = const Duration(seconds: 15),
  })  : _meta = meta,
        _client = client ?? http.Client();

  final String? Function(String cle) _meta;
  final http.Client _client;

  /// Duree maximale d'un envoi avant d'abandonner (§14 : l'echec rejoue).
  final Duration delai;

  /// Dernier retour observe (badge 4G) : mis a jour a chaque requete partie.
  bool? _serveurRepondu;

  @override
  bool? get serveurRepondu => _serveurRepondu;

  @override
  Future<ReponseServeur> envoyer(Enveloppe enveloppe) async {
    final String? racine = _racine();
    if (racine == null) {
      // Rien n'est tente sans racine : on ne decide pas de l'etat du reseau.
      return const ReponseServeur(
        code: 0,
        erreur: 'api_base absente de la table meta',
      );
    }
    final String? jeton = _meta('api_token');
    try {
      final http.Response reponse = await _client
          .post(
            Uri.parse('$racine/evenements'),
            headers: <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
              if (jeton != null && jeton.isNotEmpty)
                'Authorization': 'Bearer $jeton',
              'X-Gateway-Id': enveloppe.gatewayId,
              'X-Protocol-Version': _meta('vers_protocole') ?? '1.0',
            },
            body: jsonEncode(enveloppe.toJson()),
          )
          .timeout(delai);
      // Une reponse HTTP, meme un 500, prouve que le serveur est la.
      _serveurRepondu = true;
      return ReponseServeur(
        code: reponse.statusCode,
        erreur: reponse.statusCode >= 400 && reponse.statusCode != 409
            ? _court(reponse.body)
            : null,
      );
    } catch (e) {
      _serveurRepondu = false;
      return ReponseServeur(code: 0, erreur: _court('$e'));
    }
  }

  /// Racine de l'API lue dans `meta`, sans slash final.
  ///
  /// Relue a chaque appel : changer `api_base` ne demande aucun
  /// redemarrage. `null` = la configuration est vide, rien n'est tentable.
  String? _racine() {
    final String base = _meta('api_base') ?? '';
    if (base.isEmpty) return null;
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  @override
  Future<Affectation?> lireAffectation() async {
    final String? racine = _racine();
    if (racine == null) return null;
    final String? jeton = _meta('api_token');
    // Une reponse HTTP, meme vide ou illisible, prouve que le serveur est
    // la : seuls un timeout ou un hote absent comptent comme « aucun retour ».
    bool reponseRecue = false;
    try {
      final http.Response reponse = await _client
          .get(
            Uri.parse('$racine/affectation'),
            headers: <String, String>{
              if (jeton != null && jeton.isNotEmpty)
                'Authorization': 'Bearer $jeton',
              'X-Protocol-Version': _meta('vers_protocole') ?? '1.0',
            },
          )
          .timeout(delai);
      reponseRecue = true;
      _serveurRepondu = true;
      // 404 = pas d'affectation en cours, 4xx/5xx = serveur en defaut :
      // dans les deux cas on conserve la valeur deja connue, jamais on
      // n'efface une destination pour une erreur de passage.
      if (reponse.statusCode != 200) return null;
      final Object? brut = jsonDecode(reponse.body);
      if (brut is! Map<String, Object?>) return null;
      final Object? bloc = brut['affectation'];
      if (bloc is! Map<String, Object?>) return null;

      final Map<String, String> champs = <String, String>{};
      bloc.forEach((String cle, Object? valeur) {
        if (valeur != null) champs[cle] = '$valeur';
      });
      if (champs.isEmpty) return null;
      final Object? valideLe = brut['valide_le'];
      return Affectation(
        champs: champs,
        valideLe: valideLe == null ? null : '$valideLe',
      );
    } catch (_) {
      // Reseau absent, timeout, corps illisible : rien n'est perdu (REQ-012).
      _serveurRepondu = reponseRecue;
      return null;
    }
  }

  /// Une erreur tient en une ligne du journal, pas en un dump HTML.
  static String _court(String texte) {
    final String ligne = texte.trim().split('\n').first;
    return ligne.length > 100 ? '${ligne.substring(0, 100)}…' : ligne;
  }
}

/// Double de test : rend la reponse demandee et enregistre chaque appel.
///
/// [reponse] se modifie entre deux passes pour jouer un serveur qui revient,
/// et `appels` permet de verifier l'enveloppe effectivement partie (§12).
class TransmetteurFactice implements Transmetteur {
  TransmetteurFactice({this.reponse = const ReponseServeur(code: 202)});

  /// Reponse rendue au prochain appel.
  ReponseServeur reponse;

  /// Enveloppes recues, dans l'ordre.
  final List<Enveloppe> appels = <Enveloppe>[];

  /// Affectation rendue a chaque [lireAffectation] : `null` joue un serveur
  /// muet, et le conservateur doit alors garder la valeur connue.
  Affectation? affectation;

  /// Nombre de lectures, pour verifier la cadence du worker.
  int nombreDeLectures = 0;

  int get nombreDAppels => appels.length;

  /// Retour simule : suivi de [reponse] (`code = 0` = reseau coupe).
  bool? _serveurRepondu;

  @override
  bool? get serveurRepondu => _serveurRepondu;

  void vider() {
    appels.clear();
    nombreDeLectures = 0;
    _serveurRepondu = null;
  }

  @override
  Future<ReponseServeur> envoyer(Enveloppe enveloppe) async {
    appels.add(enveloppe);
    _serveurRepondu = reponse.code > 0;
    return reponse;
  }

  @override
  Future<Affectation?> lireAffectation() async {
    nombreDeLectures++;
    _serveurRepondu = reponse.code > 0;
    return affectation;
  }
}
