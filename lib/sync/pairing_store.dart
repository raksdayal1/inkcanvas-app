// Persisted list of peer devices this device has already approved for
// sync, so pairing only has to happen once per pair of devices - see
// SyncConnection for where an unrecognized device gets a fresh approval
// prompt instead of connecting straight through.
import 'dart:convert';
import 'dart:io';

class TrustedDevice {
  TrustedDevice({required this.id, required this.name});

  final String id;
  String name; // kept updated with whatever the peer calls itself now

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  static TrustedDevice fromJson(Map<String, dynamic> json) =>
      TrustedDevice(id: json['id'] as String, name: json['name'] as String);
}

class PairingStore {
  PairingStore._(this._file);

  final File _file;
  final Map<String, TrustedDevice> _trusted = {};

  static Future<PairingStore> load(Directory appDir) async {
    final store = PairingStore._(File('${appDir.path}/trusted_devices.json'));
    await store._load();
    return store;
  }

  Future<void> _load() async {
    if (!await _file.exists()) return;
    try {
      final raw = await _file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw) as List;
      for (final entry in decoded) {
        final device = TrustedDevice.fromJson(entry as Map<String, dynamic>);
        _trusted[device.id] = device;
      }
    } catch (e) {
      // ignore: avoid_print
      print('PairingStore: failed to read trusted_devices.json: $e');
    }
  }

  bool isTrusted(String deviceId) => _trusted.containsKey(deviceId);

  List<TrustedDevice> get trustedDevices => _trusted.values.toList();

  /// Called once a device has been approved (via the pairing dialog) -
  /// or again later, to keep its remembered display name current.
  Future<void> trust(String deviceId, String deviceName) async {
    _trusted[deviceId] = TrustedDevice(id: deviceId, name: deviceName);
    await _persist();
  }

  Future<void> revoke(String deviceId) async {
    if (_trusted.remove(deviceId) != null) await _persist();
  }

  Future<void> _persist() async {
    final data = _trusted.values.map((d) => d.toJson()).toList();
    await _file.writeAsString(jsonEncode(data));
  }
}
