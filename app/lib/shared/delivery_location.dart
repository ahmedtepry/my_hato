import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

/// A delivery address counts as located when it has a GPS pin or a typed location description.
bool addressHasLocation(Map<String, dynamic>? a) {
  if (a == null) return false;
  final pin = a['latitude'] != null && a['longitude'] != null;
  final note = (a['location_note'] as String?)?.trim().isNotEmpty ?? false;
  // a typed location only counts once the customer confirmed it (and gave a landmark)
  final landmark = (a['landmark'] as String?)?.trim().isNotEmpty ?? false;
  return pin || (note && a['location_confirmed'] == true && landmark);
}

/// Asks for the location permission if needed and returns the current position, or null when
/// the customer says no, the permission is blocked, or location is switched off.
Future<Position?> currentPosition() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
    );
  } catch (_) {
    return null;
  }
}

Uri mapUri(num lat, num lng) => Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');

/// Google Maps link for a delivery address: the exact pin when the customer shared one, otherwise a search
/// built from the typed location and the address text.
Uri addressMapUri(Map<String, dynamic> a) {
  final lat = a['latitude'], lng = a['longitude'];
  if (lat is num && lng is num) return mapUri(lat, lng);
  final text = [a['location_note'], a['street'], a['building'], a['city'], a['governorate']]
      .where((x) => x != null && '$x'.trim().isNotEmpty)
      .join(' ');
  return Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': text});
}

/// Turn-by-turn directions to the customer, when there is a GPS pin.
Uri? addressRouteUri(Map<String, dynamic> a) {
  final lat = a['latitude'], lng = a['longitude'];
  if (lat is! num || lng is! num) return null;
  return Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving');
}

/// Address parts worked out from a GPS point; any part may be null when the map service does not know it.
class GuessedAddress {
  const GuessedAddress({this.governorate, this.city, this.street, this.building});
  final String? governorate, city, street, building;
  bool get isEmpty => governorate == null && city == null && street == null && building == null;
}

String _norm(String s) => s
    .replaceAll(RegExp(r'[\u064B-\u065F]'), '')
    .replaceAll(RegExp('[أإآ]'), 'ا')
    .replaceAll('ى', 'ي')
    .replaceAll('ة', 'ه')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase();

const _enGovernorates = {
  'cairo': 'القاهرة', 'giza': 'الجيزة', 'alexandria': 'الإسكندرية', 'qalyubia': 'القليوبية', 'sharqia': 'الشرقية',
  'dakahlia': 'الدقهلية', 'gharbia': 'الغربية', 'monufia': 'المنوفية', 'beheira': 'البحيرة', 'kafr el sheikh': 'كفر الشيخ',
  'damietta': 'دمياط', 'port said': 'بورسعيد', 'ismailia': 'الإسماعيلية', 'suez': 'السويس', 'faiyum': 'الفيوم', 'fayoum': 'الفيوم',
  'beni suef': 'بني سويف', 'minya': 'المنيا', 'asyut': 'أسيوط', 'assiut': 'أسيوط', 'sohag': 'سوهاج', 'qena': 'قنا', 'luxor': 'الأقصر',
  'aswan': 'أسوان', 'red sea': 'البحر الأحمر', 'new valley': 'الوادي الجديد', 'matrouh': 'مطروح', 'north sinai': 'شمال سيناء',
  'south sinai': 'جنوب سيناء',
};

/// Turns a GPS point into governorate, area, street and building number. Returns null when it cannot be worked out.
Future<GuessedAddress?> addressFromPosition(double lat, double lng, List<String> governorates) async {
  try {
    await setLocaleIdentifier('ar_EG');
    final marks = await placemarkFromCoordinates(lat, lng).timeout(const Duration(seconds: 10));
    if (marks.isEmpty) return null;
    String? pick(Iterable<String?> xs) {
      for (final x in xs) {
        final t = x?.trim() ?? '';
        if (t.isNotEmpty && !t.contains('+')) return t; // skip plus codes such as 9QFH+XY
      }
      return null;
    }

    final p = marks.first;
    String? gov;
    final rawGov = _norm((p.administrativeArea ?? '').replaceAll(RegExp('محافظة|governorate', caseSensitive: false), ''));
    for (final g in governorates) {
      if (_norm(g) == rawGov) gov = g;
    }
    gov ??= _enGovernorates[rawGov] != null && governorates.contains(_enGovernorates[rawGov]) ? _enGovernorates[rawGov] : null;
    final number = p.subThoroughfare?.trim();
    var street = pick([p.thoroughfare, p.street]);
    if (street != null && number != null && street.startsWith(number)) street = street.substring(number.length).trim();
    final g = GuessedAddress(
      governorate: gov,
      city: pick([p.subLocality, p.locality, p.subAdministrativeArea]),
      street: street,
      building: number != null && number.isNotEmpty && !number.contains('+') ? number : null,
    );
    return g.isEmpty ? null : g;
  } catch (_) {
    return null;
  }
}
