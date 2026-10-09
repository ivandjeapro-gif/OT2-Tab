import 'dart:typed_data';

/// Un profil de la table `profils` (CDC §2.3, REQ-002).
///
/// Le CDC ne parle que du **rôle** : `ROLE_TAB1`, `ROLE_TAB2` ou `ROLE_TAB3`,
/// enregistré localement à l'enrôlement. C'est [roleCdc] qui range l'appareil
/// dans la table `equipements` et qui décide de la passerelle BLE/Wi-Fi.
///
/// Le profil est le même rôle vu par l'interface : son libellé de bouton, son
/// titre d'écran et son rang de présentation. Rien n'est écrit ici en dur —
/// la liste vient de `base.profils()` et peut donc être corrigée sans
/// redéployer l'application.
class Profil {
  const Profil({
    required this.code,
    required this.libelle,
    required this.titre,
    required this.roleCdc,
    required this.icone,
    required this.ordre,
    this.actif = true,
  });

  /// Code interne, cle primaire de la table : `dt`, `excavator`, `spotter`.
  final String code;

  /// Texte du bouton de sélection (« Driving Truck - DT »).
  final String libelle;

  /// Titre affiché par l'écran du profil.
  final String titre;

  /// Rôle porté par l'équipement (CDC §2.3, REQ-002) : `ROLE_TAB1` à `TAB3`.
  ///
  /// Une seule application, trois rôles. Les identifiants et les noms
  /// proposés au login ne viennent pas d'ici : ils sont lus dans
  /// `equipements` (`BaseLocale.idsDuProfil`, `BaseLocale.nomsDuProfil`).
  final String roleCdc;

  /// Code d'icône Material, réservé à l'affichage.
  final String icone;

  /// Rang de présentation dans le sélecteur.
  final int ordre;

  /// Vrai si le profil est proposé à la connexion.
  final bool actif;

  @override
  bool operator ==(Object other) => other is Profil && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'Profil($code)';
}

/// Une ligne de donnees saisie par le spotter.
///
/// Le blast, le bloc et la carte ne sont volontairement pas stockes ici : une
/// ligne appartient toujours a un seul bloc (une seule carte), donc ces
/// informations se deduisent de l'arbre Blast > BlocTravail. Les dupliquer
/// obligerait a les resynchroniser a chaque ajout, avec le risque qu'une ligne
/// se retrouve rattachee au mauvais bloc.
class LigneBlast {
  const LigneBlast({
    required this.time,
    required this.dt,
    required this.idDt,
    this.hasPicture = false,
    this.photo,
    this.comment = '',
  });

  final String time;

  /// Type du DT choisi dans la premiere liste (1500, 785, 2000).
  final String dt;

  /// Numero du DT, choisi dans le lot du type. Depend de [dt] : un numero
  /// n'existe que dans le lot de son type.
  final String idDt;

  final bool hasPicture;

  /// Octets de la photo reellement capturee sur l'appareil. Null quand la
  /// ligne n'a pas de photo (ou qu'elle vient d'un seed qui ne porte que le
  /// drapeau [hasPicture]).
  final Uint8List? photo;

  final String comment;
}

/// Une categorie de DT, avec le lot de DT qui la compose.
///
/// Le type est le chapeau de la premiere liste deroulante, et ses [ids] sont
/// ce que propose la seconde : les deux listes sont liees, choisir un type
/// change le contenu du lot.
///
/// Les identifiants sont non redondants sur tout le parc : le DT 01 n'existe
/// que dans la famille 1500, il ne peut donc pas apparaitre dans une autre
/// famille.
class TypeDT {
  const TypeDT({required this.code, required this.ids});

  final String code;
  final List<String> ids;

  int get nombreDts => ids.length;

  /// Nom affiche par la liste deroulante : « DT 1500 ».
  String get libelle => 'DT $code';

  /// Vrai si ce numero appartient bien a ce type de DT.
  bool contient(String id) => ids.contains(id);
}

/// Un bloc de travail : appartient a un seul blast.
///
/// Toutes les lignes saisies dans le tableau du spotter appartiennent au bloc
/// selectionne, jamais a un autre.
///
/// Le bloc ne porte pas de carte : elle appartient au blast, donc tous les
/// blocs d'un meme blast travaillent sur la meme carte.
class BlocTravail {
  BlocTravail({
    required this.numero,
    List<LigneBlast>? lignes,
    this.verrouille = false,
  }) : lignes = lignes ?? <LigneBlast>[];

  final String numero;

  final List<LigneBlast> lignes;

  /// Vrai quand ce bloc (et lui seul) est verrouille.
  ///
  /// Le verrou porte sur la **paire (blast, bloc)** et non sur le blast
  /// entier : verrouiller le bloc 8 laisse le bloc 6 du meme blast
  /// libre de recevoir des lignes, jusqu'a ce qu'on change de selection
  /// (la paire change donc le verrou « saute »).
  bool verrouille;

  int get nombreLignes => lignes.length;
}

/// Un blast : donne un nombre de blocs, une seule carte et son plan JPG.
///
/// La carte est liee au blast et non au bloc : selectionner le blast la
/// selectionne de facto, il n'y a rien a choisir a part. Les blocs heritent
/// tous de cette carte.
class Blast {
  Blast({
    required this.numero,
    required this.blocs,
    required this.carte,
    required this.plan,
    this.envoye = false,
  });

  final String numero;
  final List<BlocTravail> blocs;

  /// Code de la carte unique du blast, cle etrangere vers la table des cartes.
  final String carte;

  /// Fichier JPG du plan de [carte] : le blast ne detient que celui-ci.
  final String plan;

  /// Vrai quand **tous** les blocs de ce blast sont verrouilles.
  ///
  /// Le verrou lui-meme vit sur chaque bloc (paire blast/bloc) : ce getter
  /// ne fait que dire si le blast est integralement ferme, ce que lit le
  /// mode d'envoi `blast` et les affichages « - verrouille ».
  bool get verrouille => blocs.isNotEmpty && blocs.every((b) => b.verrouille);

  /// Vrai quand les donnees de ce blast ont ete transmises au point d'acces.
  ///
  /// Perd ce statut des que l'un de ses blocs est rouvert : les donnees
  /// deviennent de nouveau modifiables, donc elles ne sont plus a jour.
  bool envoye;

  /// Nombre de blocs du blast, affiche dans la selection.
  int get nombreBlocs => blocs.length;

  BlocTravail? bloc(String numero) {
    for (final bloc in blocs) {
      if (bloc.numero == numero) return bloc;
    }
    return null;
  }

  /// Nombre de lignes du blast entier, tous blocs confondus.
  int get nombreLignes =>
      blocs.fold<int>(0, (total, bloc) => total + bloc.nombreLignes);
}
