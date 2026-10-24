import 'package:geolocator/geolocator.dart';

/// A delivery address counts as located when it has a GPS pin or a typed location description.
bool addressHasLocation(Map<String, dynamic>? a) {
  if (a == null) return false;
  final pin = a['latitude'] != null && a['longitude'] != null;
  final note = (a['location_note'] as String?)?.trim().isNotEmpty ?? false;
  return pin || note;
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
