import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/library_controller.dart';
import '../sync/discovery.dart';
import '../sync/pairing_store.dart';
import '../sync/sync_engine.dart';

/// Lets the user see nearby devices, connect to one (auto-discovered or
/// by typing its IP), and manage which devices are trusted to sync with
/// this one. Pairing *approval* itself doesn't happen here though - see
/// [PairingApprovalGate] in main.dart, which pops up an Allow/Deny dialog
/// the moment a new device asks to pair, from wherever the user happens
/// to be in the app.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '${SyncEngine.preferredTcpPort}');
  bool _connecting = false;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final syncEngine = context.watch<SyncEngine>();
    return Scaffold(
      appBar: AppBar(title: const Text('Sync devices')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ThisDeviceCard(syncEngine: syncEngine),
          const SizedBox(height: 24),
          Text('Nearby devices', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (syncEngine.discoveredPeers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Looking for other Na-Pustakam devices on this network…',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          for (final peer in syncEngine.discoveredPeers)
            Card(
              child: ListTile(
                leading: Icon(syncEngine.isConnectedTo(peer.deviceId) ? Icons.link : Icons.devices_other),
                title: Text(peer.deviceName),
                subtitle: Text('${peer.address.address}:${peer.tcpPort}'),
                trailing: syncEngine.isConnectedTo(peer.deviceId)
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Chip(label: Text('Connected')),
                          const SizedBox(width: 4),
                          TextButton(
                            onPressed: () => syncEngine.disconnectFrom(peer.deviceId),
                            child: const Text('Disconnect'),
                          ),
                        ],
                      )
                    : FilledButton(
                        onPressed: () => _connectToPeer(syncEngine, peer),
                        child: const Text('Connect'),
                      ),
              ),
            ),
          const SizedBox(height: 24),
          Text('Connect by IP address', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            "Use this if the other device isn't showing up above - for example a "
            "Wi-Fi network that blocks broadcasts between devices.",
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostController,
                  decoration: const InputDecoration(labelText: 'IP address', hintText: '192.168.1.23'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _portController,
                  decoration: const InputDecoration(labelText: 'Port'),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _connecting ? null : _connectManually,
                child: _connecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Connect'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Trusted devices', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (syncEngine.pairingStore.trustedDevices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No paired devices yet.', style: TextStyle(color: Colors.grey)),
            ),
          for (final device in syncEngine.pairingStore.trustedDevices)
            Card(
              child: ListTile(
                leading: Icon(
                  syncEngine.isConnectedTo(device.id) ? Icons.link : Icons.check_circle_outline,
                  color: syncEngine.isConnectedTo(device.id) ? Colors.green : null,
                ),
                title: Text(device.name),
                subtitle: Text(syncEngine.isConnectedTo(device.id) ? 'Connected now' : 'Not connected right now'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (syncEngine.isConnectedTo(device.id))
                      TextButton(
                        onPressed: () => syncEngine.disconnectFrom(device.id),
                        child: const Text('Disconnect'),
                      ),
                    TextButton(
                      onPressed: () => _revoke(syncEngine, device),
                      child: const Text('Forget'),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 8),
          Text('Danger zone', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.red)),
          const SizedBox(height: 4),
          const Text(
            "Erases every notebook, image, and paired device on THIS device only - "
            "the other device keeps its own copy. Use this to start fresh, the way "
            "uninstalling and reinstalling the app would (which already happens "
            "automatically on Android, but not on Windows).",
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red)),
            onPressed: _clearAllData,
            child: const Text('Clear all data on this device'),
          ),
        ],
      ),
    );
  }

  Future<void> _clearAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all data?'),
        content: const Text(
          "This permanently deletes every notebook and image stored on this "
          "device, forgets every paired device, and gives this device a "
          "brand-new identity - exactly like uninstalling and reinstalling "
          "the app. The other device's copy is not affected, but this "
          "device will need to be paired again to resume syncing with it.\n\n"
          "This can't be undone. The app will close afterward - reopen it "
          "manually to finish starting fresh.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear everything', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final syncEngine = context.read<SyncEngine>();
    final library = context.read<LibraryController>();
    await syncEngine.stop();
    await library.clearAllData();
    // The DeviceIdentity/PairingStore/LibraryController this process
    // already loaded into memory have no idea their files just vanished
    // and would happily keep working (and re-write those files) if left
    // running - so rather than try to reset every one of them in place,
    // just end the process. Next launch starts clean since there's
    // nothing left on disk to load.
    exit(0);
  }

  Future<void> _connectToPeer(SyncEngine syncEngine, DiscoveredPeer peer) async {
    try {
      await syncEngine.connectToDiscovered(peer);
    } catch (e) {
      _showError("Couldn't connect to ${peer.deviceName}: $e");
    }
  }

  Future<void> _connectManually() async {
    final syncEngine = context.read<SyncEngine>();
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    if (host.isEmpty || port == null) {
      _showError('Enter a valid IP address and port.');
      return;
    }
    setState(() => _connecting = true);
    try {
      await syncEngine.connectManually(host, port);
    } catch (e) {
      _showError("Couldn't connect to $host:$port: $e");
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _revoke(SyncEngine syncEngine, TrustedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget "${device.name}"?'),
        content: const Text(
          "Notebooks it owns will show up read-only here until you pair with it again.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Forget')),
        ],
      ),
    );
    if (confirmed == true) await syncEngine.pairingStore.revoke(device.id);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ThisDeviceCard extends StatefulWidget {
  const _ThisDeviceCard({required this.syncEngine});

  final SyncEngine syncEngine;

  @override
  State<_ThisDeviceCard> createState() => _ThisDeviceCardState();
}

class _ThisDeviceCardState extends State<_ThisDeviceCard> {
  @override
  Widget build(BuildContext context) {
    final syncEngine = widget.syncEngine;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.devices),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This device: ${syncEngine.identity.name}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: 'Rename this device',
                  onPressed: _rename,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${syncEngine.connectedDeviceIds.length} device(s) connected right now',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            FutureBuilder<List<String>>(
              future: syncEngine.myLocalAddresses(),
              builder: (context, snapshot) {
                final addresses = snapshot.data;
                if (addresses == null || addresses.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    "This device's address: ${addresses.join(', ')}:${syncEngine.myTcpPort ?? '?'}",
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: widget.syncEngine.identity.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename this device'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('OK')),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      await widget.syncEngine.identity.rename(newName);
      // DeviceIdentity isn't itself a ChangeNotifier - nudge this card to
      // rebuild now that its name has changed.
      if (mounted) setState(() {});
    }
  }
}
