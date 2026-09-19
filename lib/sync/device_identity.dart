// This device's stable identity for sync purposes. Generated once on
// first run and persisted to disk, so:
//  - a Notebook can remember which device created it (Notebook.
//    ownerDeviceId), which is what decides whether it's editable or
//    read-only on any given device - see the ownership comment there.
//  - the pairing store (pairing_store.dart) can remember which peer
//    devices have already been approved, so pairing only has to happen
//    once per pair of devices.
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:uuid/uuid.dart';

class DeviceIdentity {
  DeviceIdentity._(this.id, this._name, this._file);

  /// Stable for the life of this install - never changes once generated.
  final String id;

  String _name;
  /// Human-friendly label shown in the pairing/approval UI and on
  /// read-only notebooks ("owned by <name>"). Editable - see [rename] -
  /// since we can't reliably read a real device model name without an
  /// extra plugin, so it starts as a generic default.
  String get name => _name;

  final File _file;

  static DeviceIdentity? _cached;

  /// Loads this device's identity, generating and persisting one on
  /// first run. [appDir] is the same Na-Pustakam folder LocalStore uses,
  /// so everything the app owns stays under that one folder.
  static Future<DeviceIdentity> load(Directory appDir) async {
    final cached = _cached;
    if (cached != null) return cached;

    final file = File('${appDir.path}/device.json');
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final identity = DeviceIdentity._(json['id'] as String, json['name'] as String, file);
        return _cached = identity;
      } catch (e) {
        // ignore: avoid_print
        print('DeviceIdentity: failed to read device.json, generating a new identity: $e');
      }
    }

    final identity = DeviceIdentity._(const Uuid().v4(), await _defaultName(), file);
    await identity._save();
    return _cached = identity;
  }

  static Future<String> _defaultName() async {
    if (Platform.isWindows) {
      final computerName = Platform.environment['COMPUTERNAME'];
      return (computerName == null || computerName.isEmpty) ? 'Windows PC' : computerName;
    }
    if (Platform.isAndroid) {
      // Unlike Windows' COMPUTERNAME, Android doesn't expose the personal
      // nickname you gave the device (e.g. in Bluetooth/system settings)
      // to third-party apps without extra runtime permissions we'd
      // otherwise have no reason to ask for. Manufacturer + model (e.g.
      // "Samsung SM-X710") is the closest thing available for free, and
      // beats a generic "Android device" default when there's more than
      // one Android device pairing in - a real personal name is still
      // just a rename away in the Sync screen (see [rename]).
      try {
        final info = await DeviceInfoPlugin().androidInfo;
        final manufacturer = info.manufacturer.trim();
        final model = info.model.trim();
        if (model.isEmpty) return 'Android device';
        if (manufacturer.isEmpty || model.toLowerCase().startsWith(manufacturer.toLowerCase())) {
          return model;
        }
        return '${manufacturer[0].toUpperCase()}${manufacturer.substring(1)} $model';
      } catch (_) {
        return 'Android device';
      }
    }
    return Platform.operatingSystem;
  }

  /// Lets the user give this device a clearer name (e.g. "Rakshit's
  /// Tablet") from the sync settings screen - purely cosmetic, doesn't
  /// affect [id] or anything already synced.
  Future<void> rename(String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == _name) return;
    _name = trimmed;
    await _save();
  }

  Future<void> _save() async {
    await _file.writeAsString(jsonEncode({'id': id, 'name': _name}));
  }
}
