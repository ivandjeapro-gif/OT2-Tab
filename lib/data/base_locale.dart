import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import '../communication/position/service_position.dart';

/// Base de donnees locale de l'application.
///
/// Deux regimes coexistent :
/// - **persistee** : [ouvrir] a reussi, un fichier SQLite est ouvert ; chaque
///   ecriture met d'abord l'etat en memoire a jour (l'interface reste
///   synchrone), puis la replicate sur disque dans une file ordonnee ;
/// - **en memoire** : aucune base disponible (pas de canal platform, environ-
///   ment de test) ; les seeds servent de donnees de depart et rien ne survit
///   a l'arret de l'application.
///
/// Tables (CDC §13, §12, §9, §23) :
/// - `meta`        : versions application / protocole / modele (§23)
/// - `profils`     : roles, libelles et rangs proposes au login (§2.3)
/// - `equipements` : identifiants enrroles et leur role (REQ-002)
/// - `cartes`, `positions`, `types_dt`, `ids_dt` : referentiel
/// - `blasts`, `blocs`, `lignes` : le domaine du spotter
/// - `journal`     : preuve des ecritures acceptees
/// - `evenements`  : file PENDING / SENDING / SYNCED (REQ-014, §14)
/// - `affectation` : destination / dumping area choisies par le serveur
class BaseLocale {
  /// [blasts] : liste de depart, vide en production (les blasts arrivent du
  /// serveur) ; les tests l'injectent avec [blastsDemo] pour disposer des
  /// memes 119/120/121 que la demo sans les semer pour les vrais utilisateurs.
  /// La liste par defaut doit rester **modifiable** : [_recharger] la vide et
  /// la recharge depuis le disque (`const []` planterait sur `clear()`).
  BaseLocale({List<Blast>? blasts})
      : _typesDT = _typesDTInit(),
        _carteLabel = _carteLabelsInit(),
        _positions = _positionsInit(),
        _equipements = _equipementsInit(),
        blasts = blasts ?? <Blast>[];

  /// Version du modele de donnees (CDC §23). Toute evolution du schema passe
  /// par une incrementation ici : [openDatabase] declenche alors [_versionner].
  ///
  /// - v1 : schema initial ;
  /// - v2 : `evenements.gateway_id` (enveloppe §12) et
  ///   `evenements.prochaine_tentative` (rejeu §14) ;
  /// - v3 : `equipements.nom` alimente le menu « Name » de la connexion ;
  /// - v4 : table `affectation`, destination/dumping area fournies par le
  ///   serveur (aucune saisie locale) ;
  /// - v5 : table `profils` et `equipements.profil` : le login lit ses
  ///   boutons dans la base au lieu d'une enum codee en dur (§2.3) ;
  /// - v6 : `blocs.verrouille` : le verrou porte sur la paire (blast, bloc),
  ///   plus sur le blast entier ; la colonne `blasts.verrouille` n'est plus
  ///   ecrite (elle reste en place sur les anciens fichiers, sans usage).
  static const int versionModele = 6;

  /// Roles CDC (REQ-002) : les trois valeurs possibles a l'enrolement.
  static const String roleTab1 = 'ROLE_TAB1';
  static const String roleTab2 = 'ROLE_TAB2';
  static const String roleTab3 = 'ROLE_TAB3';

  /// Versions visibles par l'application, ecrites dans `meta` a la creation.
  static const Map<String, String> versions = <String, String>{
    'vers_app': '1.0.0',
    'vers_protocole': '1.0',
    'vers_modele': '6.0',
  };

  /// Modes d'envoi du bouton « Envoyer », choisis dans `meta.envoi_mode`
  /// (cle documentee dans PARAMETRES.md) :
  /// - [envoiModeBlast] : tout le blast, tous ses blocs verrouilles ;
  /// - [envoiModeBloc] : le seul bloc courant, verrouille ;
  /// - [envoiModeVerrouilles] : tous les blocs verrouilles du blast.
  static const String envoiModeBlast = 'blast';
  static const String envoiModeBloc = 'bloc';
  static const String envoiModeVerrouilles = 'verrouilles';

  /// Mode d'envoi courant, lu dans `meta` a chaque appel (cle absente =
  /// [envoiModeBlast], comportement historique).
  String get envoiMode {
    final String brut = _meta['envoi_mode'] ?? '';
    switch (brut) {
      case envoiModeBloc:
      case envoiModeVerrouilles:
        return brut;
      default:
        return envoiModeBlast;
    }
  }

  /// Categories de DT. Chaque categorie porte son propre lot de numeros : c'est
  /// ce qui rend le second menu dependant du premier.
  final List<TypeDT> _typesDT;

  /// Libelle lisible des codes de carte (A1 -> Fosse A - niveau 1).
  final Map<String, String> _carteLabel;

  /// Points geographiques connus : depart du DT, destinations, dumping areas.
  ///
  /// Cle = code du point (celui que la session porte dans `destination` ou
  /// `dumpingArea`), valeur = WGS84. La carte de suivi ne lit que la.
  final Map<String, ({double lat, double lng})> _positions;

  final List<Blast> blasts;

  /// Journal des ecritures. Sans vraie base sur disque, c'est ce qui prouve
  /// que le verrouillage a bien enregistre le travail du blast.
  final List<String> journal = [];

  /// Motif du dernier refus, pour que l'ecran puisse l'expliquer.
  String? refusEnCours;

  Database? _db;
  Future<void> _ouverture = Future<void>.value();
  Future<void> _fileEcritures = Future<void>.value();

  /// Equipements enrroles, par code de profil (REQ-002).
  ///
  /// L'identifiant et le nom voyagent ensemble : ce sont les deux colonnes de
  /// la meme ligne `equipements`. Les deux menus de la connexion sont donc
  /// alimentes par la meme source et ne peuvent pas proposer une paire
  /// inexistante. La cle est le code du profil, sa colonne `role` porte le
  /// role CDC de la meme ligne.
  final Map<String, List<({String id, String nom})>> _equipements;

  /// Profils proposes au login (CDC §2.3), tries par [Profil.ordre].
  ///
  /// Lis dans la table `profils` : le bouton affiche le libelle de la
  /// ligne, pas une chaine du code. Les valeurs de depart servent le
  /// regime « memoire seule », ou aucun fichier n'est ouvert.
  final List<Profil> _profils = _profilsInit();

  /// Versions lues dans la table `meta`, renseinees des le demarrage (§23).
  final Map<String, String> _meta = <String, String>{...versions};

  /// Evenements en attente de transmission (PENDING).
  ///
  /// Compteur tenu en memoire de part et d'autre : incremente a chaque ecriture
  /// metier, recalcule sur disque quand la base est chargee.
  int _enAttente = 0;

  /// Affectation courante, fournie par le serveur (destination, dumping
  /// area, mission) : cle -> (valeur, horodatage de validation).
  ///
  /// Vide tant que le serveur n'a rien renvoye : l'ecran affiche alors
  /// « en attente » plutot que d'inventer un point. Rien n'ecrit ici depuis
  /// l'interface — seul [enregistrerAffectation] remplit la table.
  final Map<String, ({String valeur, String? horodatage})> _affectation =
      <String, ({String valeur, String? horodatage})>{};

  /// Identifiant de l'appareil inscrit comme `source_device` (CDC §12).
  String _appareil = '';

  /// Identifiant de la passerelle qui relaie les evenements (`gateway_id`).
  ///
  /// Tant qu'aucune passerelle n'est declaree, une tablette qui ecrit ses
  /// propres evenements est sa propre source : les deux colonnes coincident.
  String _passerelle = '';

  /// Vrai quand un fichier est ouvert et que les ecritures sont sauvegardees.
  bool get estPersistee => _db != null;

  // ----------------------------------------------------------------- ouverture

  /// Ouvre le fichier local, cree le schema au premier lancement, recharge les
  /// donnees depuis le disque.
  ///
  /// Idempotente et jamais rejetante : si la base est inaccessible, l'app
  /// continue en memoire plutot que de s'arreter sur un ecran blanc.
  Future<void> ouvrir({String? chemin}) => _ouverture = _ouverture.then(
        (_) => _ouvrirBase(chemin),
      );

  Future<void> _ouvrirBase(String? chemin) async {
    if (_db != null) return;
    try {
      final String dossier = await getDatabasesPath();
      final Database db = await openDatabase(
        chemin ?? '$dossier/ore_tracking.db',
        version: versionModele,
        onConfigure: (Database db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _creer,
        onUpgrade: _versionner,
      );
      _db = db;
      await _recharger(db);
    } catch (e) {
      _db = null;
      debugPrint('Base locale indisponible (fonctionnement en memoire) : $e');
    }
  }

  /// Ferme le fichier apres avoir vide la file d'ecritures.
  Future<void> fermer() async {
    await attendreEcritures();
    await _db?.close();
    _db = null;
    _ouverture = Future<void>.value();
  }

  /// Prochaine ecriture terminee : les tests l'appellent pour relire le disque.
  Future<void> attendreEcritures() => _fileEcritures;

  // -------------------------------------------------------------------- schema

  Future<void> _creer(Database db, int version) async {
    await db.execute('''
      CREATE TABLE meta (
        cle TEXT PRIMARY KEY,
        valeur TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE equipements (
        role TEXT NOT NULL,
        profil TEXT NOT NULL DEFAULT '',
        id TEXT NOT NULL,
        nom TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (role, id)
      )
    ''');
    await db.execute('''
      CREATE TABLE cartes (
        code TEXT PRIMARY KEY,
        libelle TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE positions (
        code TEXT PRIMARY KEY,
        lat REAL NOT NULL,
        lng REAL NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE types_dt (
        code TEXT NOT NULL PRIMARY KEY
      )
    ''');
    await db.execute('''
      CREATE TABLE ids_dt (
        code_type TEXT NOT NULL,
        id TEXT NOT NULL,
        PRIMARY KEY (code_type, id)
      )
    ''');
    await db.execute('''
      CREATE TABLE blasts (
        numero TEXT PRIMARY KEY,
        carte TEXT NOT NULL,
        plan TEXT NOT NULL,
        envoye INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // v6 : le verrou vit sur la paire (blast, bloc), pas sur le blast entier.
    await db.execute('''
      CREATE TABLE blocs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        blast TEXT NOT NULL,
        numero TEXT NOT NULL,
        verrouille INTEGER NOT NULL DEFAULT 0,
        UNIQUE (blast, numero)
      )
    ''');
    await db.execute('''
      CREATE TABLE lignes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bloc_id INTEGER NOT NULL,
        time TEXT NOT NULL,
        dt TEXT NOT NULL,
        id_dt TEXT NOT NULL,
        has_picture INTEGER NOT NULL DEFAULT 0,
        photo BLOB,
        comment TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE journal (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        horodatage TEXT NOT NULL,
        requete TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE evenements (
        event_id TEXT PRIMARY KEY,
        gateway_id TEXT NOT NULL DEFAULT '',
        source_device TEXT NOT NULL,
        event_type TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        payload TEXT NOT NULL,
        rssi INTEGER,
        etat TEXT NOT NULL DEFAULT 'PENDING',
        tentatives INTEGER NOT NULL DEFAULT 0,
        prochaine_tentative INTEGER
      )
    ''');
    await db.execute('CREATE INDEX idx_evenements_etat ON evenements (etat)');
    // Destination et dumping area : paires cle/valeur fournies par le
    // serveur. La table garde l'horodatage de validation pour l'ecran.
    await db.execute(_tableAffectation);
    // Profils (§2.3) : boutons, titres et rangs du login.
    await db.execute(_tableProfils);
    await _semer(db);
  }

  /// Table profils (v5). `IF NOT EXISTS` : voir [_tableAffectation].
  static const String _tableProfils = '''
      CREATE TABLE IF NOT EXISTS profils (
        code TEXT PRIMARY KEY,
        libelle TEXT NOT NULL,
        titre TEXT NOT NULL DEFAULT '',
        role_cdc TEXT NOT NULL,
        icone TEXT NOT NULL DEFAULT '',
        ordre INTEGER NOT NULL DEFAULT 0,
        actif INTEGER NOT NULL DEFAULT 1
      )
    ''';

  /// Table affectation (v4). `IF NOT EXISTS` : un fichier deja a jour qui
  /// repasse par la migration (ex. retour de version, restauration) ne doit
  /// pas exploser sur une table qu'il possede deja.
  static const String _tableAffectation = '''
      CREATE TABLE IF NOT EXISTS affectation (
        cle TEXT PRIMARY KEY,
        valeur TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'SERVEUR',
        horodatage TEXT
      )
    ''';

  /// Evolution du schema (CDC §23 : version du modele de donnees).
  ///
  /// [de] est la version du fichier ouvert : chaque palier écrit sa migration
  /// ici, sans jamais creer de table deux fois.
  Future<void> _versionner(Database db, int de, int vers) async {
    if (de < 2) {
      // v2 : l'enveloppe du §12 porte la passerelle, et le rejeu du §14 doit
      // savoir a quand remettre un essai sans harceler le serveur.
      await db.execute(
        "ALTER TABLE evenements ADD COLUMN gateway_id TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        'ALTER TABLE evenements ADD COLUMN prochaine_tentative INTEGER',
      );
      // La version visible (§23) suit le schema : sinon `meta` dirait encore
      // 1.0 pendant que la table porte deja les colonnes de la v2.
      await db.insert(
        'meta',
        <String, Object?>{
          'cle': 'vers_modele',
          'valeur': versions['vers_modele']!,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (de < 3) {
      // v3 : le menu « Name » lit la base. Les fichiers crees avant cette
      // version portent `nom = ''` : on les complete depuis la meme source
      // que le seed, pour ne pas laisser deux verites sur les equipements.
      _equipementsInit().forEach((
        String code,
        List<({String id, String nom})> lot,
      ) {
        // A ce palier, la colonne `equipements.profil` n'existe pas encore :
        // la cle reste le role CDC.
        final String role = _roleDuCode(code) ?? '';
        for (final ({String id, String nom}) e in lot) {
          db.update(
            'equipements',
            <String, Object?>{'nom': e.nom},
            where: 'role = ? AND id = ?',
            whereArgs: <Object?>[role, e.id],
          );
        }
      });
      await db.insert(
        'meta',
        <String, Object?>{
          'cle': 'vers_modele',
          'valeur': versions['vers_modele']!,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (de < 4) {
      // v4 : le serveur choisit la destination et la dumping area. La table
      // n'est pas encore remplie : le premier passage de 4G la remplit.
      await db.execute(_tableAffectation);
      await db.insert(
        'meta',
        <String, Object?>{
          'cle': 'vers_modele',
          'valeur': versions['vers_modele']!,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (de < 5) {
      // v5 : les boutons du login sortent de la base (§2.3). Le fichier
      // d'avant n'a ni table `profils` ni colonne `equipements.profil` :
      // on cree la table, on ajoute la colonne, puis on la remplit depuis
      // le role deja enrrole — le role est la verite du CDC, le profil
      // n'est que sa lecture par l'interface.
      await db.execute(_tableProfils);
      await db.execute(
        "ALTER TABLE equipements ADD COLUMN profil TEXT NOT NULL DEFAULT ''",
      );
      for (final Profil profil in _profilsInit()) {
        await db.update(
          'equipements',
          <String, Object?>{'profil': profil.code},
          where: 'role = ?',
          whereArgs: <Object?>[profil.roleCdc],
        );
      }
      final int dejaLa = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM profils'),
          ) ??
          0;
      if (dejaLa == 0) {
        final Batch batch = db.batch();
        for (final Profil profil in _profilsInit()) {
          batch.insert('profils', _profilValeurs(profil));
        }
        await batch.commit(noResult: true);
      }
      await db.insert(
        'meta',
        <String, Object?>{
          'cle': 'vers_modele',
          'valeur': versions['vers_modele']!,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    if (de < 6) {
      // v6 : le verrou descend du blast vers chaque bloc (paire blast/bloc).
      // La colonne `blasts.verrouille` reste en place (elle ne gene pas) mais
      // n'est plus lue ni ecrite : l'etat veritable est sur chaque ligne
      // `blocs`. Garde-fou `PRAGMA table_info` : un fichier deja porte de la
      // colonne ne doit pas planter sur un ADD COLUMN duplique.
      final List<Map<String, Object?>> infos = await db.rawQuery(
        'PRAGMA table_info(blocs)',
      );
      final bool dejaLa = infos.any((row) => row['name'] == 'verrouille');
      if (!dejaLa) {
        await db.execute(
          'ALTER TABLE blocs ADD COLUMN verrouille INTEGER NOT NULL DEFAULT 0',
        );
      }
      await db.insert(
        'meta',
        <String, Object?>{
          'cle': 'vers_modele',
          'valeur': versions['vers_modele']!,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// Ecrit les donnees de depart dans un schema vierge.
  Future<void> _semer(Database db) async {
    final Batch batch = db.batch();
    _meta.forEach((String cle, String valeur) {
      batch.insert('meta', <String, Object?>{'cle': cle, 'valeur': valeur});
    });
    for (final Profil profil in _profilsInit()) {
      batch.insert('profils', _profilValeurs(profil));
    }
    _equipements.forEach((String code, List<({String id, String nom})> lot) {
      final String role = _roleDuCode(code) ?? '';
      for (final ({String id, String nom}) e in lot) {
        batch.insert(
          'equipements',
          <String, Object?>{
            'role': role,
            'profil': code,
            'id': e.id,
            'nom': e.nom,
          },
        );
      }
    });
    _carteLabel.forEach((String code, String libelle) {
      batch.insert('cartes', <String, Object?>{'code': code, 'libelle': libelle});
    });
    _positions.forEach(
      (String code, ({double lat, double lng}) point) {
        batch.insert(
          'positions',
          <String, Object?>{'code': code, 'lat': point.lat, 'lng': point.lng},
        );
      },
    );
    for (final TypeDT type in _typesDT) {
      batch.insert('types_dt', <String, Object?>{'code': type.code});
      for (final String id in type.ids) {
        batch.insert('ids_dt', <String, Object?>{'code_type': type.code, 'id': id});
      }
    }
    await batch.commit(noResult: true);

    // Blasts, blocs et lignes : les identifiants AUTOINCREMENT doivent etre
    // connus ligne a ligne, donc pas de lot ici. Le verrou (v6) se pose sur
    // chaque bloc ; `blasts.verrouille` n'est plus ecrite.
    for (final Blast blast in blasts) {
      await db.insert('blasts', <String, Object?>{
        'numero': blast.numero,
        'carte': blast.carte,
        'plan': blast.plan,
        'envoye': blast.envoye ? 1 : 0,
      });
      for (final BlocTravail bloc in blast.blocs) {
        final int blocId = await db.insert('blocs', <String, Object?>{
          'blast': blast.numero,
          'numero': bloc.numero,
          'verrouille': bloc.verrouille ? 1 : 0,
        });
        // La liste porte la ligne la plus recente en tete : on inscrit dans
        // l'ordre inverse pour que `ORDER BY rowid DESC` la restitue a l'identique.
        for (final LigneBlast ligne in bloc.lignes.reversed) {
          await db.insert('lignes', _ligneValeurs(blocId, ligne));
        }
      }
    }
  }

  // ------------------------------------------------------------------ lecture

  Map<String, Object?> _ligneValeurs(int blocId, LigneBlast ligne) =>
      <String, Object?>{
        'bloc_id': blocId,
        'time': ligne.time,
        'dt': ligne.dt,
        'id_dt': ligne.idDt,
        'has_picture': ligne.hasPicture ? 1 : 0,
        'photo': ligne.photo,
        'comment': ligne.comment,
      };

  /// Remplace les donnees en memoire par celles du disque.
  Future<void> _recharger(Database db) async {
    // §24 : un envoi interrompu par un arret brutal ne doit rester ni coincé
    // en SENDING, ni invisible du compteur, ni perdu. Il repart en file.
    await db.rawUpdate(
      "UPDATE evenements SET etat = 'PENDING' WHERE etat = 'SENDING'",
    );

    _meta
      ..clear()
      ..addEntries(
        (await db.query('meta')).map(
          (row) => MapEntry<String, String>(
            row['cle']! as String,
            row['valeur']! as String,
          ),
        ),
      );

    _profils
      ..clear()
      ..addAll(
        (await db.query('profils', orderBy: 'ordre, rowid'))
            .map(_profilLigne),
      );

    _equipements.clear();
    for (final row in await db.query('equipements', orderBy: 'rowid')) {
      final String role = row['role']! as String;
      // `profil` est la cle de lecture ; le role sert de repli pour un
      // fichier ou la colonne existe mais n'est pas encore remplie.
      final String brut = (row['profil'] as String?) ?? '';
      final String code = brut.isEmpty ? (_codeDuRole(role) ?? role) : brut;
      (_equipements[code] ??= <({String id, String nom})>[]).add(
        (id: row['id']! as String, nom: (row['nom'] as String?) ?? ''),
      );
    }

    _carteLabel
      ..clear()
      ..addEntries(
        (await db.query('cartes')).map(
          (row) => MapEntry<String, String>(
            row['code']! as String,
            row['libelle']! as String,
          ),
        ),
      );

    _positions
      ..clear()
      ..addEntries(
        (await db.query('positions')).map(
          (row) => MapEntry<String, ({double lat, double lng})>(
            row['code']! as String,
            (lat: (row['lat']! as num).toDouble(), lng: (row['lng']! as num).toDouble()),
          ),
        ),
      );

    _typesDT.clear();
    for (final row in await db.query('types_dt', orderBy: 'rowid')) {
      final String code = row['code']! as String;
      final List<String> ids = (await db.query(
        'ids_dt',
        where: 'code_type = ?',
        whereArgs: <Object?>[code],
        orderBy: 'rowid',
      ))
          .map((r) => r['id']! as String)
          .toList();
      _typesDT.add(TypeDT(code: code, ids: ids));
    }

    final List<Blast> relus = <Blast>[];
    for (final row in await db.query('blasts', orderBy: 'rowid')) {
      final Blast blast = Blast(
        numero: row['numero']! as String,
        carte: row['carte']! as String,
        plan: row['plan']! as String,
        envoye: (row['envoye']! as int) != 0,
        blocs: <BlocTravail>[],
      );
      final rowsBlocs = await db.query(
        'blocs',
        where: 'blast = ?',
        whereArgs: <Object?>[blast.numero],
        orderBy: 'rowid',
      );
      for (final rowBloc in rowsBlocs) {
        final BlocTravail bloc = BlocTravail(
          numero: rowBloc['numero']! as String,
          verrouille: (rowBloc['verrouille']! as int) != 0,
        );
        final rowsLignes = await db.query(
          'lignes',
          where: 'bloc_id = ?',
          whereArgs: <Object?>[rowBloc['id']! as int],
          orderBy: 'rowid DESC',
        );
        for (final rowLigne in rowsLignes) {
          bloc.lignes.add(
            LigneBlast(
              time: rowLigne['time']! as String,
              dt: rowLigne['dt']! as String,
              idDt: rowLigne['id_dt']! as String,
              hasPicture: (rowLigne['has_picture']! as int) != 0,
              photo: _octets(rowLigne['photo']),
              comment: (rowLigne['comment'] as String?) ?? '',
            ),
          );
        }
        blast.blocs.add(bloc);
      }
      relus.add(blast);
    }
    blasts
      ..clear()
      ..addAll(relus);

    _affectation.clear();
    for (final row in await db.query('affectation', orderBy: 'rowid')) {
      _affectation[row['cle']! as String] = (
        valeur: row['valeur']! as String,
        horodatage: row['horodatage'] as String?,
      );
    }

    final rowsJournal = await db.query('journal', orderBy: 'rowid DESC');
    journal
      ..clear()
      ..addAll(
        rowsJournal.map((row) {
          final String horodatage = row['horodatage']! as String;
          return '${horodatage.substring(11, 19)}  ${row['requete']! as String}';
        }),
      );

    _enAttente = Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM evenements WHERE etat = ?',
            <Object?>['PENDING'],
          ),
        ) ??
        0;
  }

  static Uint8List? _octets(Object? valeur) {
    if (valeur == null) return null;
    if (valeur is Uint8List) return valeur;
    if (valeur is List<int>) return Uint8List.fromList(valeur);
    return null;
  }

  // ---------------------------------------------------------------- ecritures

  /// Replique une operation sur disque, dans l'ordre des appels.
  ///
  /// L'interface reste synchrone : la memoire est deja juste quand on revient
  /// de l'appel metier, le fichier suit dans la foulée.
  void _ecrire(Future<void> Function(Database db) operation) {
    final Database? db = _db;
    if (db == null) return;
    _fileEcritures = _fileEcritures.then((_) => operation(db)).catchError(
          (Object e) => debugPrint('Ecriture locale refusee : $e'),
        );
  }

  Future<int?> _idDuBloc(Database db, String blast, String numero) async {
    final rows = await db.query(
      'blocs',
      columns: <String>['id'],
      where: 'blast = ? AND numero = ?',
      whereArgs: <Object?>[blast, numero],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id']! as int;
  }

  /// Pose un evenement dans la file d'attente (CDC §12).
  ///
  /// `rssi` reste nul tant que la couche radio n'existe pas : la colonne est
  /// des d'ores et deja ouverte (décision C3).
  void _evenement(String type, Map<String, Object?> contenu) {
    _enAttente++;
    _ecrire(
      (Database db) => db.insert(
        'evenements',
        <String, Object?>{
          'event_id': _uuid(),
          'gateway_id': _passerelle.isEmpty ? _appareil : _passerelle,
          'source_device': _appareil,
          'event_type': type,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'payload': jsonEncode(contenu),
          'rssi': null,
          'etat': 'PENDING',
          'tentatives': 0,
        },
      ),
    );
  }

  /// Identifiant applicatif unique (REQ-014) : UUID v4 genere sur place.
  static String _uuid() {
    final Random rng = Random.secure();
    final List<int> o = List<int>.generate(16, (_) => rng.nextInt(256));
    o[6] = (o[6] & 0x0f) | 0x40;
    o[8] = (o[8] & 0x3f) | 0x80;
    String h(int i) => o[i].toRadixString(16).padLeft(2, '0');
    return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
        '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
  }

  // ---------------------------------------------------------------- lectures

  /// Categories de DT proposees par la premiere liste deroulante.
  List<TypeDT> get typesDT => List<TypeDT>.unmodifiable(_typesDT);

  /// Lot de numeros du type choisi, pour la seconde liste deroulante.
  ///
  /// Depend du type : la liste est filtree par la categorie, donc on ne peut
  /// pas enregistrer le numero 9 d'une categorie de 2000 tonnes sur une ligne
  /// declaree en 1500.
  List<String> idsDuType(String codeType) =>
      typeDT(codeType)?.ids ?? const <String>[];

  List<String> get numerosBlast =>
      blasts.map((blast) => blast.numero).toList();

  Blast? parNumero(String numero) {
    for (final blast in blasts) {
      if (blast.numero == numero) return blast;
    }
    return null;
  }

  /// Blocs d'un blast : alimente la liste « Select bloc ».
  List<BlocTravail> blocsDe(String numero) => parNumero(numero)?.blocs ?? [];

  String? libelleCarte(String code) => _carteLabel[code];

  /// Code du point de depart du DT : c'est de la que son trajet commence.
  static const String codeDepart = 'DEPOT';

  /// Coordonnees d'un point connu, ou null si le code n'existe pas.
  ({double lat, double lng})? positionDe(String code) => _positions[code];

  /// Codes des points geographiques connus.
  List<String> get codesPoints =>
      List<String>.unmodifiable(_positions.keys);

  TypeDT? typeDT(String code) {
    for (final type in _typesDT) {
      if (type.code == code) return type;
    }
    return null;
  }

  /// Famille d'un identifiant.
  ///
  /// Les identifiants sont non redondants : ce retour ne peut jamais etre
  /// ambigu. Sert a verifier qu'une ligne ne declare pas un DT dans une
  /// famille qui n'est pas la sienne.
  TypeDT? familleDuId(String id) {
    for (final type in _typesDT) {
      if (type.contient(id)) return type;
    }
    return null;
  }

  /// Profils configures (CDC §2.3), dans l'ordre de presentation.
  List<Profil> get profils => List<Profil>.unmodifiable(_profils);

  /// Profils reels de la colonne de connexion : `actif` retire ceux qui sont
  /// retires du service sans pour autant detruire leurs equipements.
  List<Profil> get profilsActifs => List<Profil>.unmodifiable(
        _profils.where((Profil profil) => profil.actif),
      );

  /// Profil de ce [code], ou null s'il n'existe pas.
  Profil? profil(String code) {
    for (final Profil profil in _profils) {
      if (profil.code == code) return profil;
    }
    return null;
  }

  /// Profil qui porte ce [role] CDC (REQ-002).
  ///
  /// Un role peut accueillir plusieurs profils : c'est le premier actif qui
  /// gagne, les autres restent configurables sans changer le login.
  Profil? profilDuRole(String role) {
    Profil? premier;
    for (final Profil profil in _profils) {
      if (profil.roleCdc != role) continue;
      if (profil.actif) return profil;
      premier ??= profil;
    }
    return premier;
  }

  /// Identifiants enrroles pour un profil, lus dans `equipements`.
  List<String> idsDuProfil(Profil profil) =>
      List<String>.unmodifiable(_lot(profil.code).map((e) => e.id));

  /// Identifiants enrroles pour un role (REQ-002).
  List<String> idsDuRole(String role) {
    final Profil? profil = profilDuRole(role);
    return profil == null ? const <String>[] : idsDuProfil(profil);
  }

  /// Noms affiches par le menu « Name », dans l'ordre de [idsDuProfil].
  ///
  /// Les deux listes sortent du meme parcours dans la meme table : elles ont
  /// la meme longueur et la meme disposition, quel que soit le profil.
  List<String> nomsDuProfil(Profil profil) =>
      List<String>.unmodifiable(_lot(profil.code).map((e) => e.nom));

  /// Noms affiches pour un role.
  List<String> nomsDuRole(String role) {
    final Profil? profil = profilDuRole(role);
    return profil == null ? const <String>[] : nomsDuProfil(profil);
  }

  /// Nom de l'equipement [id] enrrole sous ce profil, ou null.
  ///
  /// C'est la reference qui decide si un couple id/nom est coherent : la
  /// connexion interroge la base au lieu de deviner, et refuse les paires
  /// qui ne designent pas un seul et meme equipement.
  String? nomDuProfil(Profil profil, String id) {
    for (final ({String id, String nom}) e in _lot(profil.code)) {
      if (e.id == id) return e.nom;
    }
    return null;
  }

  /// Variante role de [nomDuProfil], pour les appels qui ne portent qu'un
  /// role CDC.
  String? nomDu(String role, String id) {
    final Profil? profil = profilDuRole(role);
    return profil == null ? null : nomDuProfil(profil, id);
  }

  List<({String id, String nom})> _lot(String code) =>
      _equipements[code] ?? const <({String id, String nom})>[];

  /// Identifiant de l'appareil courant, inscrit comme `source_device`.
  void declarerAppareil(String id) => _appareil = id;

  /// Identifiant de la passerelle courante, inscrit comme `gateway_id` (§12).
  void declarerPasserelle(String id) => _passerelle = id;

  /// Versions lues dans `meta` (§23).
  String? meta(String cle) => _meta[cle];

  /// Ecrit une valeur dans `meta`.
  Future<void> majMeta(String cle, String valeur) async {
    _meta[cle] = valeur;
    _ecrire(
      (Database db) => db.insert(
        'meta',
        <String, Object?>{'cle': cle, 'valeur': valeur},
        conflictAlgorithm: ConflictAlgorithm.replace,
      ),
    );
    await attendreEcritures();
  }

  // ------------------------------------------------------------- affectation

  /// Valeur fournie par le serveur (`destination`, `dumping_area`, …).
  ///
  /// `null` tant que le serveur n'a rien renvoye : l'ecran affiche alors
  /// « en attente » plutot qu'un point choisi ici.
  String? affectation(String cle) => _affectation[cle]?.valeur;

  /// Horodatage de validation de [cle], affiche en badge par l'ecran DT.
  String? horodatageAffectation(String cle) =>
      _affectation[cle]?.horodatage;

  /// Affectation courante, pour les tests et le journal.
  Map<String, ({String valeur, String? horodatage})> get toutesAffectations =>
      Map<String, ({String valeur, String? horodatage})>.unmodifiable(
        _affectation,
      );

  /// Le serveur a choisi **et valide** ces valeurs : remplacement complet.
  ///
  /// Seule porte d'ecriture de la table. L'interface n'y passe jamais :
  /// destination et dumping area sont decidees en amont, l'application ne
  /// fait que les relayer avec l'horodatage de la validation.
  Future<void> enregistrerAffectation(
    Map<String, String> champs, {
    String? horodatage,
  }) async {
    if (champs.isEmpty) return;
    _affectation
      ..clear()
      ..addEntries(
        champs.entries.map(
          (MapEntry<String, String> e) =>
              MapEntry<String, ({String valeur, String? horodatage})>(
            e.key,
            (valeur: e.value, horodatage: horodatage),
          ),
        ),
      );
    _ecrire((Database db) async {
      final Batch batch = db.batch();
      batch.rawDelete('DELETE FROM affectation');
      for (final MapEntry<String, String> e in champs.entries) {
        batch.insert(
          'affectation',
          <String, Object?>{
            'cle': e.key,
            'valeur': e.value,
            'source': 'SERVEUR',
            'horodatage': horodatage,
          },
        );
      }
      await batch.commit(noResult: true);
    });
    journaliser(
      'AFFECTATION '
      '${champs.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
    );
    await attendreEcritures();
  }

  /// Une mesure GPS du device, posee en file (CDC §5, §12).
  ///
  /// Le serveur analyse les positions pour decider destination et dumping
  /// area : chaque mesure part donc comme tout autre evenement, avec son
  /// `event_id` (idempotence REQ-015). Cadence maitrisee cote service :
  /// le GPS n'ecrit pas plus vite que [intervalle].
  void evenementPosition(PositionTerrain position) {
    _evenement('GPS_UPDATE', <String, Object?>{
      'easting': position.easting,
      'northing': position.northing,
      'elevation': position.elevation,
      if (position.wgs84 != null) ...<String, Object?>{
        'lat': position.wgs84!.lat,
        'lng': position.wgs84!.lng,
      },
    });
  }

  /// Evenements encore a transmettre (etat PENDING).
  Future<List<Map<String, Object?>>> evenementsEnAttente() async {
    final Database? db = _db;
    if (db == null) return const <Map<String, Object?>>[];
    return db.query(
      'evenements',
      where: 'etat = ?',
      whereArgs: <Object?>['PENDING'],
      orderBy: 'rowid',
    );
  }

  /// Evenements reellement eligibles : PENDING **et** tentative echue (§14).
  ///
  /// C'est ce que lit le worker de synchronisation : un evenement repousse par
  /// un backoff n'apparait pas avant l'heure. Vide sans base — il n'y a alors
  /// rien de persiste a transmettre.
  Future<List<Map<String, Object?>>> aTransmettre({
    int limite = 20,
    DateTime? maintenant,
  }) async {
    final Database? db = _db;
    if (db == null) return const <Map<String, Object?>>[];
    final int instant = (maintenant ?? DateTime.now()).millisecondsSinceEpoch;
    return db.query(
      'evenements',
      where: "etat = 'PENDING' AND "
          '(prochaine_tentative IS NULL OR prochaine_tentative <= ?)',
      whereArgs: <Object?>[instant],
      orderBy: 'rowid',
      limit: limite,
    );
  }

  /// Un evenement suivi individuellement (rejeu, tests).
  Future<Map<String, Object?>?> evenement(String eventId) async {
    final Database? db = _db;
    if (db == null) return null;
    final rows = await db.query(
      'evenements',
      where: 'event_id = ?',
      whereArgs: <Object?>[eventId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Nombre d'evenements en attente : ce que l'ecran du DT affiche (§21).
  int get nombreEnAttente => _enAttente;

  /// Un evenement part vers le serveur (etat SENDING, compteur de tentatives).
  Future<void> marquerEnCours(String eventId) async {
    final Database? db = _db;
    if (db == null) return;
    await db.rawUpdate(
      "UPDATE evenements SET etat = 'SENDING', tentatives = tentatives + 1 "
      'WHERE event_id = ?',
      <Object?>[eventId],
    );
  }

  /// Accuse de reception serveur recu (etat SYNCED, CDC §14).
  Future<void> marquerSynchronise(String eventId) async {
    final Database? db = _db;
    if (db == null) return;
    await db.update(
      'evenements',
      <String, Object?>{'etat': 'SYNCED', 'prochaine_tentative': null},
      where: 'event_id = ?',
      whereArgs: <Object?>[eventId],
    );
    await _recalculerAttente(db);
  }

  /// Echec de transmission : retour en PENDING pour un nouvel essai (§14).
  ///
  /// [nouvelleTentative] fixe le prochain essai (backoff du §14) : laissee
  /// vide, l'evenement est de nouveau immediatement eligibilable.
  Future<void> remettreEnAttente(
    String eventId, {
    DateTime? nouvelleTentative,
  }) async {
    final Database? db = _db;
    if (db == null) return;
    await db.update(
      'evenements',
      <String, Object?>{
        'etat': 'PENDING',
        'prochaine_tentative': nouvelleTentative?.millisecondsSinceEpoch,
      },
      where: 'event_id = ?',
      whereArgs: <Object?>[eventId],
    );
    await _recalculerAttente(db);
  }

  Future<void> _recalculerAttente(Database db) async {
    _enAttente = Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM evenements WHERE etat = ?',
            <Object?>['PENDING'],
          ),
        ) ??
        _enAttente;
  }

  // --------------------------------------------------------------- ecritures

  /// Evenement BLE recu d'un TAB 3, stocké par TAB 2 (CDC §10/§11/§17).
  ///
  /// Idempotence locale (REQ-015) : un event_id déjà connu n'est pas
  /// re-stocké — le remettrait deux fois dans la file de synchro.
  void evenementRecu(Map<String, Object?> evenement) {
    final String eventId = '${evenement['event_id'] ?? ''}';
    if (eventId.isEmpty || _eventIdsConnus.contains(eventId)) {
      _journalBle.insert(0, 'DUPLICAT ignoré: $eventId');
      return;
    }
    _eventIdsConnus.add(eventId);
    _evenement('BLE_RELAY', evenement);
    _journalBle.insert(0, 'BLE_RELAY $eventId de ${evenement['source_device']}');
  }

  /// Event IDs déjà traités localement (idempotence CDC §17).
  final Set<String> _eventIdsConnus = <String>{};

  /// Journal technique BLE (CDC §22) : connexions, RSSI, doublons.
  final List<String> _journalBle = <String>[];

  /// Journal technique BLE lisible par l'UI (CDC §22).
  List<String> get journalBle => List<String>.unmodifiable(_journalBle);

  bool _refuser(String motif) {
    refusEnCours = motif;
    return false;
  }

  /// Ecrit une ligne dans le journal technique (CDC §22).
  ///
  /// Sert aux ecritures metier comme aux etapes de la synchronisation : ce
  /// journal est la preuve de ce que l'application a reellement fait.
  void journaliser(String requete) {
    final String horodatage = DateTime.now().toIso8601String();
    journal.insert(0, '${horodatage.substring(11, 19)}  $requete');
    _ecrire(
      (Database db) => db.insert(
        'journal',
        <String, Object?>{'horodatage': horodatage, 'requete': requete},
      ),
    );
  }

  bool _accepter(String requete) {
    refusEnCours = null;
    journaliser(requete);
    return true;
  }

  /// Ajoute une ligne au bloc donne, en tete du tableau.
  ///
  /// Verifie que le numero du DT appartient bien a la categorie choisie : la
  /// coherence type/numero est une regle de la base, pas de l'interface.
  /// Contenu reseau d'une ligne : exactement ce que le formulaire a saisi.
  ///
  /// Un seul endroit decrit les champs, utilise par [ajouterLigne] (une
  /// ligne, LINE_ADD) et par [envoyer] (le blast entier, BLAST_SEND) : les
  /// deux ne peuvent pas diverger, et rien ne reste sur le poste.
  static Map<String, Object?> _contenuLigne(LigneBlast ligne) =>
      <String, Object?>{
        'time': ligne.time,
        'dt': ligne.dt,
        'id_dt': ligne.idDt,
        'has_picture': ligne.hasPicture,
        if (ligne.photo != null) 'photo': base64Encode(ligne.photo!),
        'comment': ligne.comment,
      };

  bool ajouterLigne(BlocTravail bloc, LigneBlast ligne) {
    final Blast? blast = _blastDe(bloc);
    if (blast == null) return _refuser('Bloc inconnu');
    // v6 : le verrou porte sur la paire (blast, bloc). Verrouiller le bloc 8
    // n'empêche pas d'ecrire dans le bloc 6 du meme blast.
    if (bloc.verrouille) {
      return _refuser(
        'Bloc ${bloc.numero} du blast ${blast.numero} verrouille : '
        'aucune ligne acceptee',
      );
    }
    final TypeDT? type = typeDT(ligne.dt);
    if (type == null) return _refuser('Categorie de DT inconnue : ${ligne.dt}');
    if (!type.contient(ligne.idDt)) {
      return _refuser(
        'Le DT n\'${ligne.idDt} n\'existe pas en categorie ${ligne.dt} '
        '(lot : ${type.ids.join(', ')})',
      );
    }
    bloc.lignes.insert(0, ligne);
    _ecrire((Database db) async {
      final int? blocId = await _idDuBloc(db, blast.numero, bloc.numero);
      if (blocId == null) return;
      await db.insert('lignes', _ligneValeurs(blocId, ligne));
    });
    // Tout ce que le formulaire a capte part avec l'evenement : heure,
    // famille, numero, drapeau photo, octets et commentaire. La photo est
    // encodee en base64 pour tenir dans le payload JSON. Aucun champ du
    // formulaire ne reste sur le poste (« toutes les donnees partent »).
    _evenement('LINE_ADD', <String, Object?>{
      'blast': blast.numero,
      'bloc': bloc.numero,
      ..._contenuLigne(ligne),
    });
    return _accepter(
      'INSERT lignes (blast ${blast.numero}, bloc ${bloc.numero}, '
      'DT ${ligne.dt} n${ligne.idDt})',
    );
  }

  /// Verrouillage d'un bloc (paire blast/bloc, v6) : ce bloc est ferme, les
  /// autres du meme blast restent ouverts tant qu'on ne les verrouille pas.
  bool verrouiller(BlocTravail bloc) {
    final Blast? blast = _blastDe(bloc);
    if (blast == null) return _refuser('Bloc inconnu');
    if (bloc.verrouille) {
      return _refuser(
        'Bloc ${bloc.numero} du blast ${blast.numero} deja verrouille',
      );
    }
    bloc.verrouille = true;
    _ecrire(
      (Database db) => db.update(
        'blocs',
        <String, Object?>{'verrouille': 1},
        where: 'blast = ? AND numero = ?',
        whereArgs: <Object?>[blast.numero, bloc.numero],
      ),
    );
    _evenement('BLAST_LOCK', <String, Object?>{
      'blast': blast.numero,
      'bloc': bloc.numero,
      'lignes': bloc.nombreLignes,
    });
    return _accepter(
      'UPDATE blocs SET verrouille = 1 WHERE blast = ${blast.numero} '
      'AND numero = ${bloc.numero} (${bloc.nombreLignes} ligne(s))',
    );
  }

  /// Reouverture d'un bloc verrouille : la saisie reprend dans CE bloc, les
  /// autres blocs verrouilles ne sont pas touches.
  bool deverrouiller(BlocTravail bloc) {
    final Blast? blast = _blastDe(bloc);
    if (blast == null) return _refuser('Bloc inconnu');
    if (!bloc.verrouille) {
      return _refuser(
        'Bloc ${bloc.numero} du blast ${blast.numero} n\'est pas verrouille',
      );
    }
    bloc.verrouille = false;
    // Les donnees redeviennent modifiables : ce qui a deja parte sur le
    // reseau n'est plus a jour, on le signale plutot que de laisser croire
    // l'inverse. Le statut « envoye » reste porte par le blast entier.
    blast.envoye = false;
    _ecrire(
      (Database db) async {
        await db.update(
          'blocs',
          <String, Object?>{'verrouille': 0},
          where: 'blast = ? AND numero = ?',
          whereArgs: <Object?>[blast.numero, bloc.numero],
        );
        await db.update(
          'blasts',
          <String, Object?>{'envoye': 0},
          where: 'numero = ?',
          whereArgs: <Object?>[blast.numero],
        );
      },
    );
    _evenement('BLAST_UNLOCK', <String, Object?>{
      'blast': blast.numero,
      'bloc': bloc.numero,
    });
    return _accepter(
      'UPDATE blocs SET verrouille = 0, blasts SET envoye = 0 '
      'WHERE blast = ${blast.numero} AND numero = ${bloc.numero}',
    );
  }

  /// Transmet les donnees sauvegardees d'un blast au point d'acces.
  ///
  /// Le perimetre depend du mode courant ([envoiMode], cle `meta.envoi_mode`) :
  /// - `blast` : snapshot **complet**, tous les blocs du blast verrouilles ;
  /// - `bloc` : le seul bloc [numeroBloc], qui doit etre verrouille ;
  /// - `verrouilles` : les seuls blocs verrouilles du blast (au moins un).
  ///
  /// Dans tous les cas, seules des donnees deja fermees partent : tant que le
  /// spotter peut encore ecrire dedans, ce ne sont pas des donnees
  /// sauvegardees. Le statut « envoye » reste porte par le blast entier.
  bool envoyer(Blast blast, {String? numeroBloc}) {
    final String mode = envoiMode;
    final List<BlocTravail> cibles;
    switch (mode) {
      case envoiModeBloc:
        final BlocTravail? bloc =
            numeroBloc == null ? null : blast.bloc(numeroBloc);
        if (bloc == null) {
          return _refuser(
            'Bloc ${numeroBloc ?? '(absent)'} introuvable '
            'dans le blast ${blast.numero}',
          );
        }
        if (!bloc.verrouille) {
          return _refuser(
            'Bloc ${bloc.numero} du blast ${blast.numero} non verrouille : '
            'verrouillez-le avant d\'envoyer',
          );
        }
        cibles = <BlocTravail>[bloc];
      case envoiModeVerrouilles:
        cibles = blast.blocs
            .where((BlocTravail b) => b.verrouille)
            .toList(growable: false);
        if (cibles.isEmpty) {
          return _refuser(
            'Aucun bloc verrouille dans le blast ${blast.numero} : '
            'verrouillez au moins un bloc avant d\'envoyer',
          );
        }
      default:
        if (!blast.verrouille) {
          return _refuser(
            'Blast ${blast.numero} non verrouille : '
            'verrouillez-le avant d\'envoyer',
          );
        }
        cibles = blast.blocs;
    }
    final int lignes = cibles.fold<int>(
      0,
      (int total, BlocTravail b) => total + b.nombreLignes,
    );
    if (lignes == 0) {
      return _refuser('Blast ${blast.numero} sans donnee : rien a envoyer');
    }
    if (blast.envoye) {
      return _refuser('Blast ${blast.numero} deja envoye');
    }
    blast.envoye = true;
    _ecrire(
      (Database db) => db.update(
        'blasts',
        <String, Object?>{'envoye': 1},
        where: 'numero = ?',
        whereArgs: <Object?>[blast.numero],
      ),
    );
    // Snapshot du perimetre choisi : le serveur recoit les lignes du mode,
    // photos comprises. C'est ce qui garantit « ne laisse rien » — y compris
    // pour les lignes de depart, qui n'ont jamais eu de LINE_ADD.
    _evenement('BLAST_SEND', <String, Object?>{
      'blast': blast.numero,
      'carte': blast.carte,
      'mode': mode,
      'lignes': lignes,
      'blocs': cibles.length,
      if (mode == envoiModeBloc) 'bloc': numeroBloc,
      'donnees': <Map<String, Object?>>[
        for (final BlocTravail bloc in cibles)
          for (final LigneBlast ligne in bloc.lignes)
            <String, Object?>{'bloc': bloc.numero, ..._contenuLigne(ligne)},
      ],
    });
    return _accepter(
      'SEND blast ${blast.numero} mode $mode - $lignes ligne(s) '
      '(${cibles.length} bloc(s), carte ${blast.carte})',
    );
  }

  Blast? _blastDe(BlocTravail bloc) {
    for (final blast in blasts) {
      if (identical(blast.bloc(bloc.numero), bloc)) return blast;
    }
    return null;
  }

  // ------------------------------------------------------------------ seeds

  /// Familles de DT, chacune avec son lot de numeros.
  ///
  /// Les identifiants sont non redondants sur tout le parc : le numero 01 n'a
  /// de place que dans la famille 1500. Le troisieme DT de chaque famille est
  /// celui que l'image source coupe en bas.
  static List<TypeDT> _typesDTInit() => <TypeDT>[
        const TypeDT(code: '1500', ids: <String>['01', '08', '14']),
        const TypeDT(code: '785', ids: <String>['09', '10', '17']),
        const TypeDT(code: '1000', ids: <String>['06', '04', '03']),
        const TypeDT(code: '2500', ids: <String>['20', '25', '28']),
      ];

  static Map<String, String> _carteLabelsInit() => <String, String>{
        'A1': 'Fosse A - niveau 1',
        'A2': 'Fosse A - niveau 2',
        'A3': 'Fosse A - niveau 3',
        'B2': 'Fosse B - niveau 2',
        'B3': 'Fosse B - niveau 3',
        'C3': 'Rompad central',
        'D1': 'Piste D - niveau 1',
        'D2': 'Piste D - niveau 2',
      };

  /// Points geographiques, en WGS84.
  ///
  /// Tous les points sont sur un meme site (~ 700 m de cote a cote) pour que
  /// la carte de suivi tienne en zoom 16 sans devoir recadrer.
  static Map<String, ({double lat, double lng})> _positionsInit() =>
      <String, ({double lat, double lng})>{
        codeDepart: (lat: 45.6720, lng: 3.1150),
        'F5M': (lat: 45.6765, lng: 3.1210),
        'RomPad 1': (lat: 45.6745, lng: 3.1085),
      };

  /// Profils de depart (§2.3) : ce que la table `profils` porte au premier
  /// lancement. Le code est la cle, le role vient du CDC, le reste est de
  /// l'affichage — tout se relit depuis la base.
  static List<Profil> _profilsInit() => <Profil>[
        Profil(
          code: 'dt',
          libelle: 'Driving Truck - DT',
          titre: 'DT',
          roleCdc: roleTab2,
          icone: 'local_shipping',
          ordre: 1,
        ),
        Profil(
          code: 'excavator',
          libelle: 'Excavator',
          titre: 'Excavator',
          roleCdc: roleTab3,
          icone: 'construction',
          ordre: 2,
        ),
        Profil(
          code: 'spotter',
          libelle: 'Geology Spotter',
          titre: 'Spotter',
          roleCdc: roleTab1,
          icone: 'explore',
          ordre: 3,
        ),
      ];

  /// Code de profil qui porte ce role CDC, dans le seed.
  static String? _codeDuRole(String role) {
    for (final Profil profil in _profilsInit()) {
      if (profil.roleCdc == role) return profil.code;
    }
    return null;
  }

  /// Role CDC de ce code de profil, dans le seed.
  static String? _roleDuCode(String code) {
    for (final Profil profil in _profilsInit()) {
      if (profil.code == code) return profil.roleCdc;
    }
    return null;
  }

  /// Ligne SQL d'un profil, dans les deux sens ([_semer] et les migrations).
  static Map<String, Object?> _profilValeurs(Profil profil) =>
      <String, Object?>{
        'code': profil.code,
        'libelle': profil.libelle,
        'titre': profil.titre,
        'role_cdc': profil.roleCdc,
        'icone': profil.icone,
        'ordre': profil.ordre,
        'actif': profil.actif ? 1 : 0,
      };

  static Profil _profilLigne(Map<String, Object?> ligne) => Profil(
        code: ligne['code']! as String,
        libelle: ligne['libelle']! as String,
        titre: (ligne['titre'] as String?) ?? '',
        roleCdc: ligne['role_cdc']! as String,
        icone: (ligne['icone'] as String?) ?? '',
        ordre: (ligne['ordre'] as num?)?.toInt() ?? 0,
        actif: ((ligne['actif'] as num?)?.toInt() ?? 1) != 0,
      );

  /// Enrolement de depart : un identifiant et son nom, tels que proposes au
  /// login, profil par profil (REQ-002).
  ///
  /// Id et nom sont donnes ensemble ici, comme ils le seront sur une
  /// inscription venue du serveur : aucun des deux menus n'est derive de
  /// l'autre a l'ecran, ils lisent les deux colonnes de la meme ligne.
  /// La cle du lot est le code du profil, la colonne `equipements.role`
  /// porte le role CDC qui lui correspond.
  static Map<String, List<({String id, String nom})>> _equipementsInit() =>
      <String, List<({String id, String nom})>>{
        'spotter': <({String id, String nom})>[
          (id: '10', nom: 'Spotter 10'),
          (id: '12', nom: 'Spotter 12'),
          (id: '18', nom: 'Spotter 18'),
        ],
        'dt': <({String id, String nom})>[
          (id: '10', nom: 'DT 10'),
          (id: '14', nom: 'DT 14'),
          (id: '15', nom: 'DT 15'),
          (id: '22', nom: 'DT 22'),
        ],
        'excavator': <({String id, String nom})>[
          (id: '7', nom: 'Excavator 7'),
          (id: '22', nom: 'Excavator 22'),
          (id: '31', nom: 'Excavator 31'),
        ],
      };

  /// Blasts de demonstration, **jamais semes en production** : le vrai
  /// travail du spotter arrive du serveur. Les tests les injectent avec
  /// `BaseLocale(blasts: BaseLocale.blastsDemo())` pour disposer des memes
  /// 119/120/121 (et de leurs lignes de depart) sans polluer les tablettes.
  @visibleForTesting
  static List<Blast> blastsDemo() => <Blast>[
        Blast(
          numero: '119',
          carte: 'A1',
          plan: 'assets/images/cartes/plans/119_A1.jpg',
          blocs: <BlocTravail>[
            BlocTravail(
              numero: '6',
              lignes: <LigneBlast>[
                LigneBlast(
                  time: '08h24',
                  dt: '1500',
                  idDt: '01',
                  hasPicture: true,
                  comment: 'Comment',
                ),
                LigneBlast(
                  time: '08h41',
                  dt: '1500',
                  idDt: '08',
                  comment: 'Fissure ouest',
                ),
              ],
            ),
            BlocTravail(numero: '7'),
            BlocTravail(numero: '8'),
          ],
        ),
        Blast(
          numero: '120',
          carte: 'B2',
          plan: 'assets/images/cartes/plans/120_B2.jpg',
          blocs: <BlocTravail>[
            BlocTravail(
              numero: '3',
              lignes: <LigneBlast>[
                LigneBlast(
                  time: '10h05',
                  dt: '785',
                  idDt: '09',
                  hasPicture: true,
                  comment: 'Roche dure',
                ),
                LigneBlast(
                  time: '10h41',
                  dt: '2500',
                  idDt: '20',
                  comment: 'Fissure nord',
                ),
              ],
            ),
            BlocTravail(numero: '4'),
            BlocTravail(numero: '5'),
          ],
        ),
        Blast(
          numero: '121',
          carte: 'D1',
          plan: 'assets/images/cartes/plans/121_D1.jpg',
          blocs: <BlocTravail>[
            BlocTravail(numero: '1'),
            BlocTravail(numero: '2'),
          ],
        ),
      ];
}
