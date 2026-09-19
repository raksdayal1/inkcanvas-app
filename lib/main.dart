import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'app_theme.dart';
import 'state/library_controller.dart';
import 'storage/local_store.dart';
import 'sync/device_identity.dart';
import 'sync/pairing_store.dart';
import 'sync/sync_engine.dart';
import 'ui/home_screen.dart';
import 'ui/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Show the splash immediately, before any of the boot work below - all
  // of that (reading device identity/pairing state and the notebook
  // library from disk) runs locally and is normally close to instant, far
  // too fast to actually register as a splash screen on its own. Booting
  // in two stages like this - one `runApp` for the splash, a second one
  // once everything's ready - both gets the splash on screen straight
  // away and (via `minSplashDuration` below) keeps it there for a beat
  // even when the real work finishes almost immediately.
  runApp(const _BootSplash());
  final minSplashDuration = Future<void>.delayed(const Duration(milliseconds: 3100));

  final store = LocalStore();
  final appDir = await store.appDirectory();
  final identity = await DeviceIdentity.load(appDir);
  final pairingStore = await PairingStore.load(appDir);

  final library = LibraryController(store, identity);
  final syncEngine = SyncEngine(
    identity: identity,
    pairingStore: pairingStore,
    library: library,
    imagesDir: await store.imagesDirectory(),
  );
  library.syncEngine = syncEngine;

  // Load from disk, then start discovery/listening - in that order so the
  // manifest we advertise as soon as a peer connects already reflects
  // what's actually on this device.
  await library.load();
  syncEngine.start();

  await minSplashDuration;

  runApp(InkCanvasApp(library: library, syncEngine: syncEngine));
}

/// What `runApp` shows for the very first frame, before the real
/// [InkCanvasApp] (with its providers, theme, etc.) exists yet - just
/// enough of a widget tree (MaterialApp, for Directionality/Material
/// ancestry) to host [SplashScreen] on its own.
class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SplashScreen(),
    );
  }
}

class InkCanvasApp extends StatelessWidget {
  const InkCanvasApp({super.key, required this.library, required this.syncEngine});

  final LibraryController library;
  final SyncEngine syncEngine;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<LibraryController>.value(value: library),
        ChangeNotifierProvider<SyncEngine>.value(value: syncEngine),
      ],
      child: MaterialApp(
        title: 'InkCanvas',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: const _AppRoot(),
      ),
    );
  }
}

/// Waits for the library to load from disk, then shows the notebook grid.
/// Notebook/section/page navigation after that is handled by
/// [LibraryController]'s own selection fields rather than named routes, so
/// the whole app is really just one screen that swaps what it shows based
/// on what's selected — simplest thing that works for a single-window app.
class _AppRoot extends StatelessWidget {
  const _AppRoot();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    if (!library.loaded) {
      return const SplashScreen();
    }
    return const _PairingApprovalGate(child: HomeScreen());
  }
}

/// Pops up an Allow/Deny dialog the moment another device asks to pair,
/// no matter which screen the user happens to be looking at - pairing
/// is rare and unpredictable (whenever the two devices first see each
/// other on the network), so it can't wait for the user to go find a
/// dedicated sync screen first.
class _PairingApprovalGate extends StatefulWidget {
  const _PairingApprovalGate({required this.child});

  final Widget child;

  @override
  State<_PairingApprovalGate> createState() => _PairingApprovalGateState();
}

class _PairingApprovalGateState extends State<_PairingApprovalGate> with WidgetsBindingObserver {
  late final SyncEngine _syncEngine;
  bool _dialogShowing = false;

  // Only a genuine sleep/background cycle passes through `paused` before
  // coming back to `resumed` - a transient focus loss (e.g. a native file
  // picker dialog opening on Windows/desktop, which only ever goes
  // resumed -> inactive -> resumed) never does. We only want to pay the
  // cost of tearing down and rebuilding the whole sync engine for the
  // former, not every time a dialog opens and closes.
  bool _wasPaused = false;

  @override
  void initState() {
    super.initState();
    _syncEngine = context.read<SyncEngine>();
    _syncEngine.addListener(_onSyncChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncEngine.removeListener(_onSyncChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _wasPaused = true;
      return;
    }
    // A device (typically Android) coming back from sleep/background is
    // exactly when the discovery socket can be left silently dead - see
    // SyncEngine.restart for why. Rebuilding it here means the app finds
    // peers again on its own the moment it's back in front of the user,
    // rather than needing a full restart to notice. But only do this for
    // a real resume-from-background - not for a transient dialog (e.g.
    // the Windows file picker used to insert an image) that never
    // actually paused the app, or we'd tear down a perfectly live sync
    // connection every time the user opens that dialog.
    if (state == AppLifecycleState.resumed && _wasPaused) {
      _wasPaused = false;
      unawaited(_syncEngine.restart());
    }
  }

  void _onSyncChanged() {
    final request = _syncEngine.pendingApprovalRequest;
    if (request == null || _dialogShowing) return;
    _dialogShowing = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PairingApprovalDialog(request: request),
    ).then((_) => _dialogShowing = false);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PairingApprovalDialog extends StatelessWidget {
  const _PairingApprovalDialog({required this.request});

  final PairingRequest request;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pairing request'),
      content: Text(
        '"${request.deviceName}" wants to sync notebooks with this device. '
        'Once allowed, it can sync again automatically without asking.',
      ),
      actions: [
        TextButton(
          onPressed: () {
            request.respond(false);
            Navigator.of(context).pop();
          },
          child: const Text('Deny'),
        ),
        FilledButton(
          onPressed: () {
            request.respond(true);
            Navigator.of(context).pop();
          },
          child: const Text('Allow'),
        ),
      ],
    );
  }
}
