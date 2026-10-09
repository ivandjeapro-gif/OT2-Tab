import 'package:proj4dart/proj4dart.dart' as proj;

void main() {
  final utm = proj.Projection.parse('+proj=utm +zone=31 +datum=WGS84 +units=m +no_defs');
  // Point(x: lng, y: lat)
  final p1 = proj.Projection.WGS84.transform(utm, proj.Point(x: 3.087, y: 45.777));
  print('x=lng,y=lat -> ${p1.x}, ${p1.y}');
  // Point(x: lat, y: lng)
  final p2 = proj.Projection.WGS84.transform(utm, proj.Point(x: 45.777, y: 3.087));
  print('x=lat,y=lng -> ${p2.x}, ${p2.y}');
  // Avec Projection.parse pour WGS84
  final wgs = proj.Projection.parse('+proj=longlat +datum=WGS84 +no_defs');
  final p3 = wgs.transform(utm, proj.Point(x: 3.087, y: 45.777));
  print('longlat x=lng,y=lat -> ${p3.x}, ${p3.y}');
}
