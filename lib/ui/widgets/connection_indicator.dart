import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../sync/sync_engine.dart';
import '../sync_screen.dart';

/// A small always-visible indicator showing whether this device is
/// currently live-synced with any other device right now - green while
/// at least one is connected, red while not. Notebooks owned by another
/// device are read-only here whenever this shows red. Tapping it opens
/// the full Sync devices screen. Meant to sit in an AppBar's actions, on
/// every screen a user might be looking at while wondering "is this even
/// connected right now" - not just a dedicated sync screen.
class ConnectionIndicator extends StatelessWidget {
  const ConnectionIndicator({super.key, this.large = false});

  /// The compact form (a small dot, used on the notes/canvas page) vs.
  /// the bigger form with a "Connected"/"Offline" label underneath it
  /// (used on the home screen, where there's room to spare and it's the
  /// first thing worth knowing when you land there).
  final bool large;

  @override
  Widget build(BuildContext context) {
    final syncEngine = context.watch<SyncEngine>();
    final connectedCount = syncEngine.connectedDeviceIds.length;
    final connected = connectedCount > 0;
    final color = connected ? Colors.green : Colors.red;
    final tooltip = connected
        ? 'Connected to $connectedCount device(s) — tap for sync settings'
        : 'Not connected to any device — tap to connect';

    if (!large) {
      return IconButton(
        tooltip: tooltip,
        icon: Icon(Icons.circle, size: 14, color: color),
        onPressed: () => _open(context),
      );
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 24, color: color),
              const SizedBox(height: 2),
              Text(
                connected ? 'Connected' : 'Offline',
                style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SyncScreen()));
}
