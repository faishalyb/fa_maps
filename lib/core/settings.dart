import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

enum CoordFormat { decimal, dms, utm }

/// Pengaturan aplikasi, disimpan lokal (SharedPreferences).
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  late SharedPreferences _prefs;

  CoordFormat coordFormat = CoordFormat.utm;
  int avgReadings = 20;          // jumlah bacaan GPS untuk dirata-rata
  double maxAccuracy = 30;       // bacaan lebih buruk dari ini dibuang (meter)
  String serverUrl = '';         // contoh: http://192.168.1.10:8080
  String deviceId = '';
  String userName = 'Petugas lapangan';
  bool onlineBaseMap = false;    // peta dasar OSM online (hanya bila ada sinyal)
  bool autoSync = true;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    coordFormat = CoordFormat.values[_prefs.getInt('coordFormat') ?? CoordFormat.utm.index];
    avgReadings = _prefs.getInt('avgReadings') ?? 20;
    maxAccuracy = _prefs.getDouble('maxAccuracy') ?? 30;
    serverUrl = _prefs.getString('serverUrl') ?? '';
    userName = _prefs.getString('userName') ?? 'Petugas lapangan';
    onlineBaseMap = _prefs.getBool('onlineBaseMap') ?? false;
    autoSync = _prefs.getBool('autoSync') ?? true;
    deviceId = _prefs.getString('deviceId') ?? '';
    if (deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await _prefs.setString('deviceId', deviceId);
    }
  }

  Future<void> update({
    CoordFormat? coordFormat,
    int? avgReadings,
    double? maxAccuracy,
    String? serverUrl,
    String? userName,
    bool? onlineBaseMap,
    bool? autoSync,
  }) async {
    if (coordFormat != null) {
      this.coordFormat = coordFormat;
      await _prefs.setInt('coordFormat', coordFormat.index);
    }
    if (avgReadings != null) {
      this.avgReadings = avgReadings;
      await _prefs.setInt('avgReadings', avgReadings);
    }
    if (maxAccuracy != null) {
      this.maxAccuracy = maxAccuracy;
      await _prefs.setDouble('maxAccuracy', maxAccuracy);
    }
    if (serverUrl != null) {
      this.serverUrl = serverUrl.trim();
      await _prefs.setString('serverUrl', this.serverUrl);
    }
    if (userName != null) {
      this.userName = userName.trim();
      await _prefs.setString('userName', this.userName);
    }
    if (onlineBaseMap != null) {
      this.onlineBaseMap = onlineBaseMap;
      await _prefs.setBool('onlineBaseMap', onlineBaseMap);
    }
    if (autoSync != null) {
      this.autoSync = autoSync;
      await _prefs.setBool('autoSync', autoSync);
    }
    notifyListeners();
  }
}
