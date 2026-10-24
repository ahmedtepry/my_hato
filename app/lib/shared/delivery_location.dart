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
