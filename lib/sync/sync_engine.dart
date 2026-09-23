// Orchestrates everything above the raw transport: discovering peers,
// pairing (with the user's approval the first time), and - once a
// connection is live - exchanging manifests and pushing/pulling
// notebooks so both devices converge on the same data. An owning
// device can always edit its own notebook; a peer's notebook is
// editable here only while we're actively connected to its owner - see
// LibraryController.canEdit, which asks this class via [isConnectedTo].
//
// Known v1 limitations, deliberately punted on for now:
//  - Conflict resolution is last-write-wins per *page* (using each
//    page's lastModified) - fine for one person editing from two of
//    their own devices, not a real multi-user CRDT.
//  - No encryption - anyone on the same LAN who already knows a
//    device's declared id could try to impersonate it. Low risk for a
//    home network between your own two devices.
//  - A notebook-level structural change (rename, add/remove a page)
//    that doesn't touch any page's lastModified could be missed by the
//    manifest comparison until the next full push.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/canvas_element.dart';
import '../models/notebook.dart';
import '../state/library_controller.dart';
import 'device_identity.dart';
import 'discovery.dart';
import 'pairing_store.dart';
import 'sync_connection.dart';

/// An incoming pairing request awaiting the user's Allow/Deny in the UI.
class PairingRequest {
  PairingRequest(this.deviceId, this.deviceName, this._respond);

  final String deviceId;
  final String deviceName;
  final void Function(bool approved) _respond;

  void respond(bool approved) => _respond(approved);
}

/// Tracks one in-flight connection through the hello/pairing handshake.
/// Messages that arrive before both sides have approved each other are
/// queued here and replayed once the link goes active, rather than
/// dropped - the two sides don't necessarily finish approving at
/// exactly the same moment.
class _PendingLink {
  _PendingLink(this.connection, {required this.locallyInitiated});

  final SyncConnection connection;
  /// True if *we* dialed out to the peer (_connectAsClient); false if the
  /// peer connected to us (_handleIncomingConnection). Used in
  /// _handleHello to tell a deliberate reconnect the user asked for apart
  /// from the peer auto-reconnecting to us behind our back after we hit
  /// Disconnect - see _manuallyDisconnected.
  final bool locallyInitiated;
  String? peerId;
  String? peerName;
  bool localApproved = false;
  bool remoteApproved = false;
  final List<Map<String, dynamic>> queuedMessages = [];
}

class SyncEngine extends ChangeNotifier {
  SyncEngine({
    required this.identity,
    required this.pairingStore,
    required this.library,
    required this.imagesDir,
  });

  final DeviceIdentity identity;
  final PairingStore pairingStore;
  final LibraryController library;

  /// Same folder LocalStore keeps images in - passed in rather than
  /// re-derived so there's exactly one place that knows that path.
  final Directory imagesDir;

  static const int preferredTcpPort = 58733;

  SyncServer? _server;
  PeerDiscovery? _discovery;

  final Map<String, SyncConnection> _connections = {}; // peerId -> active, paired connection
  final List<_PendingLink> _pendingLinks = [];
  final Map<String, Set<String>> _imagesSentToPeer = {}; // peerId -> basenames already pushed this session
  // Peers the user explicitly hit Disconnect on - discovery won't
  // auto-reconnect these even though they're still trusted, until the
  // user deliberately reconnects (Connect button, or manual IP) or the
  // app restarts. Session-only by design: unlike PairingStore.revoke,
  // this isn't meant to be permanent.
  final Set<String> _manuallyDisconnected = {};

  List<DiscoveredPeer> discoveredPeers = [];
  PairingRequest? pendingApprovalRequest;

  bool get isRunning => _discovery != null;
  int? get myTcpPort => _server?.boundPort;
  Set<String> get connectedDeviceIds => _connections.keys.toSet();
  bool isConnectedTo(String deviceId) => _connections.containsKey(deviceId);

  /// Closes the live connection to [deviceId], if there is one right now.
  /// This does NOT revoke trust (see PairingStore.revoke for that) - the
  /// device just goes back to being read-only/disconnected until it
  /// reconnects on its own, which still happens automatically the next
  /// time discovery sees it again, since "approve once, remember it"
  /// means a trusted device never needs to ask again. The rest of the
  /// cleanup (removing it from [connectedDeviceIds], clearing the
  /// per-peer sent-images cache, notifying listeners) happens the normal
  /// way, via the same onClosed handling any dropped connection goes
  /// through - see _attachLink/_detachLink.
  void disconnectFrom(String deviceId) {
    _manuallyDisconnected.add(deviceId);
    _connections[deviceId]?.close();
  }

  Future<List<String>> myLocalAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return interfaces.expand((i) => i.addresses).map((a) => a.address).toList();
    } catch (e) {
      // ignore: avoid_print
      print('SyncEngine: failed to list network interfaces: $e');
      return const [];
    }
  }

  Future<void> start() async {
    if (_discovery != null) return;
    var server = SyncServer(preferredTcpPort);
    Stream<SyncConnection> incoming;
    try {
      incoming = await server.start();
    } catch (e) {
      // Preferred port already busy (e.g. the app restarted quickly and
      // the old socket hasn't been released yet) - fall back to
      // whatever the OS hands out. Peers still find us fine, since
      // discovery always advertises our *actual* bound port.
      // ignore: avoid_print
      print('SyncEngine: preferred port busy ($e), asking the OS for one instead');
      server = SyncServer(0);
      incoming = await server.start();
    }
    _server = server;
    incoming.listen(_handleIncomingConnection);

    final discovery = PeerDiscovery(
      myDeviceId: identity.id,
      myDeviceName: identity.name,
      tcpPort: server.boundPort!,
    );
    _discovery = discovery;
    discovery.peers.listen(_handleDiscoveredPeers);
    await discovery.start();
  }

  Future<void> stop() async {
    for (final connection in _connections.values) {
      await connection.close();
    }
    _connections.clear();
    for (final link in List.of(_pendingLinks)) {
      await link.connection.close();
    }
    _pendingLinks.clear();
    await _discovery?.stop();
    _discovery = null;
    await _server?.stop();
    _server = null;
  }

  /// Tears down and rebuilds the discovery socket, TCP listener, and any
  /// live connections, then starts fresh. Call this after the OS may
  /// have silently broken the old sockets without either side seeing an
  /// error for it - the case this exists for is a device (typically
  /// Android) going to sleep: Wi-Fi gets suspended or reassociates with
  /// a new address on wake, and the broadcast UDP socket discovery uses
  /// can come out of that no longer actually sending or receiving
  /// anything, without ever throwing - so nothing here would otherwise
  /// notice, and both devices are left unable to find each other again
  /// until the app restarts. See main.dart's _SyncLifecycleObserver,
  /// which calls this whenever the app returns to the foreground.
  Future<void> restart() async {
    if (_discovery == null && _server == null) return; // never started (or already stopped) - nothing to do
    await stop();
    discoveredPeers = [];
    notifyListeners();
    await start();
  }

  // --- Discovery + connecting -----------------------------------------

  void _handleDiscoveredPeers(List<DiscoveredPeer> peers) {
    discoveredPeers = peers;
    for (final peer in peers) {
      final alreadyLinked = isConnectedTo(peer.deviceId) ||
          _pendingLinks.any((link) => link.peerId == peer.deviceId);
      if (pairingStore.isTrusted(peer.deviceId) && !alreadyLinked && !_manuallyDisconnected.contains(peer.deviceId)) {
        // Already-paired devices reconnect with no prompt the moment
        // they see each other again - a brand-new device only connects
        // when the user explicitly asks (see connectManually /
        // connectToDiscovered), so pairing a stranger always requires a
        // deliberate step.
        unawaited(_connectAsClient(peer.address, peer.tcpPort, peer.deviceName, manual: false));
      }
    }
    notifyListeners();
  }

  Future<void> connectToDiscovered(DiscoveredPeer peer) =>
      _connectAsClient(peer.address, peer.tcpPort, peer.deviceName, manual: true);

  Future<void> connectManually(String host, int port) async {
    final address = InternetAddress.tryParse(host);
    if (address == null) {
      throw FormatException('"$host" doesn\'t look like a valid IP address');
    }
    await _connectAsClient(address, port, null, manual: true);
  }

  /// [manual] is true only for a connection attempt a human just asked
  /// for right now (the Connect button on a discovered peer, or typing
  /// in an IP) - as opposed to [_handleDiscoveredPeers] quietly
  /// reconnecting to an already-trusted peer the moment discovery sees
  /// it again. It travels in the hello message below so the *other*
  /// device can tell the two apart too - see _handleHello, which needs
  /// that to let a deliberate reconnect through even when the peer on
  /// the other end is the one that hit Disconnect, not us.
  Future<void> _connectAsClient(
    InternetAddress address,
    int port,
    String? peerNameHint, {
    required bool manual,
  }) async {
    SyncConnection connection;
    try {
      connection = await connectToPeer(address, port);
    } catch (e) {
      // ignore: avoid_print
      print('SyncEngine: failed to connect to $address:$port: $e');
      rethrow;
    }
    _attachLink(connection, locallyInitiated: true, manual: manual);
  }

  void _handleIncomingConnection(SyncConnection connection) =>
      _attachLink(connection, locallyInitiated: false, manual: false);

  void _attachLink(SyncConnection connection, {required bool locallyInitiated, required bool manual}) {
    final link = _PendingLink(connection, locallyInitiated: locallyInitiated);
    _pendingLinks.add(link);
    connection.messages.listen((message) => _handleMessage(link, message));
    connection.onClosed.listen((_) => _detachLink(link));
    // manual is only meaningful when we're the one dialing out
    // (locallyInitiated) - an incoming connection didn't originate from
    // any action of ours, so there's nothing to report about it either
    // way; false is just a harmless placeholder there.
    connection.send({
      'type': 'hello',
      'deviceId': identity.id,
      'deviceName': identity.name,
      'manual': manual,
    });
  }

  void _detachLink(_PendingLink link) {
    _pendingLinks.remove(link);
    final peerId = link.peerId;
    if (peerId != null && _connections[peerId] == link.connection) {
      _connections.remove(peerId);
      _imagesSentToPeer.remove(peerId);
      if (pendingApprovalRequest?.deviceId == peerId) pendingApprovalRequest = null;
      notifyListeners();
    }
  }

  // --- Handshake + pairing ---------------------------------------------

  void _handleMessage(_PendingLink link, Map<String, dynamic> message) {
    final isActive = link.peerId != null && _connections[link.peerId] == link.connection;
    final type = message['type'];
    if (!isActive &&
        (type == 'manifest' || type == 'notebook-request' || type == 'notebook-data' || type == 'notebook-deleted')) {
      // Pairing hasn't finished settling on this side yet - hang on to
      // it and replay once it has, rather than silently losing it.
      link.queuedMessages.add(message);
      return;
    }
    switch (type) {
      case 'hello':
        _handleHello(link, message);
      case 'pairing-response':
        _handlePairingResponse(link, message);
      case 'manifest':
        unawaited(_handleManifest(link, message));
      case 'notebook-request':
        unawaited(_handleNotebookRequest(link, message));
      case 'notebook-data':
        unawaited(_handleNotebookData(link, message));
      case 'notebook-deleted':
        unawaited(
          library.applyNotebookDeletion(
            message['notebookId'] as String,
            DateTime.parse(message['deletedAt'] as String),
          ),
        );
    }
  }

  void _handleHello(_PendingLink link, Map<String, dynamic> message) {
    final peerId = message['deviceId'] as String;
    final peerName = message['deviceName'] as String;
    link.peerId = peerId;
    link.peerName = peerName;

    if (_manuallyDisconnected.contains(peerId)) {
      final peerDialedDeliberately = message['manual'] == true;
      if (!link.locallyInitiated && !peerDialedDeliberately) {
        // Neither side asked for this: we didn't dial out ourselves
        // (locallyInitiated), and the peer says this wasn't a deliberate
        // Connect either - it's just their own discovery quietly
        // reconnecting to us the moment it sees us again, exactly what
        // hitting Disconnect is supposed to prevent. Refuse it.
        link.connection.close();
        return;
      }
      // Either we're the one dialing out here (Connect button, or
      // manual IP), or the peer is and says so - either way a human
      // asked for this reconnect just now, even if it wasn't the same
      // human (or device) that hit Disconnect in the first place. Let
      // future auto-reconnects resume from here on.
      _manuallyDisconnected.remove(peerId);
    }

    if (_connections.containsKey(peerId)) {
      // Both sides raced to connect to each other at once - keep
      // whichever link got there first, drop this duplicate.
      link.connection.close();
      return;
    }

    if (pairingStore.isTrusted(peerId)) {
      link.localApproved = true;
      link.connection.send({'type': 'pairing-response', 'approved': true});
      _maybeActivate(link);
    } else {
      pendingApprovalRequest = PairingRequest(peerId, peerName, (approved) {
        _resolvePairing(link, approved);
      });
      notifyListeners();
    }
  }

  /// Called by the UI (via [PairingRequest.respond]) after the user taps
  /// Allow or Deny on a first-time pairing prompt.
  void _resolvePairing(_PendingLink link, bool approved) {
    if (pendingApprovalRequest?.deviceId == link.peerId) {
      pendingApprovalRequest = null;
    }
    if (approved) {
      final peerId = link.peerId!;
      unawaited(pairingStore.trust(peerId, link.peerName ?? 'Unknown device'));
      link.localApproved = true;
      link.connection.send({'type': 'pairing-response', 'approved': true});
      _maybeActivate(link);
    } else {
      link.connection.send({'type': 'pairing-response', 'approved': false});
      link.connection.close();
    }
    notifyListeners();
  }

  void _handlePairingResponse(_PendingLink link, Map<String, dynamic> message) {
    if (message['approved'] != true) {
      link.connection.close();
      return;
    }
    link.remoteApproved = true;
    _maybeActivate(link);
  }

  void _maybeActivate(_PendingLink link) {
    if (!link.localApproved || !link.remoteApproved) return;
    final peerId = link.peerId;
    if (peerId == null) return;
    if (_connections.containsKey(peerId)) {
      link.connection.close(); // another link for this peer beat us to it
      return;
    }
    _connections[peerId] = link.connection;
    notifyListeners();
    _sendManifest(link.connection);
    final queued = List.of(link.queuedMessages);
    link.queuedMessages.clear();
    for (final message in queued) {
      _handleMessage(link, message);
    }
  }

  // --- Manifest / notebook sync ----------------------------------------

  void _sendManifest(SyncConnection connection) {
    final entries = library.notebooks
        .map((notebook) => {'id': notebook.id, 'freshness': _freshness(notebook).toIso8601String()})
        .toList();
    final deletedEntries = library.deletedNotebookIds.entries
        .map((e) => {'id': e.key, 'deletedAt': e.value.toIso8601String()})
        .toList();
    connection.send({'type': 'manifest', 'notebooks': entries, 'deletedNotebooks': deletedEntries});
  }

  // Notebook.lastModified (bumped by LibraryController on every mutation -
  // a rename, a section/page created/renamed/deleted, a canvas edit) is
  // the freshness signal itself now, rather than a scan of its pages'
  // lastModified. That scan couldn't see a rename, a section-only change,
  // or a delete (nothing left to scan) - which is exactly why those
  // stopped reaching the other device. Kept as a same-named method so the
  // two call sites below didn't need to change.
  DateTime _freshness(Notebook notebook) => notebook.lastModified;

  Notebook? _findLocalNotebook(String id) {
    for (final notebook in library.notebooks) {
      if (notebook.id == id) return notebook;
    }
    return null;
  }

  Future<void> _handleManifest(_PendingLink link, Map<String, dynamic> message) async {
    final peerId = link.peerId;
    final connection = peerId == null ? null : _connections[peerId];
    if (peerId == null || connection == null) return;

    // Apply any notebook deletions the peer knows about *first* - so the
    // per-notebook comparison below, which iterates library.notebooks,
    // simply never sees a notebook that was just tombstoned away and
    // therefore never tries to helpfully push or re-request it.
    final remoteDeletedEntries = (message['deletedNotebooks'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    for (final entry in remoteDeletedEntries) {
      await library.applyNotebookDeletion(entry['id'] as String, DateTime.parse(entry['deletedAt'] as String));
    }

    final remoteEntries = (message['notebooks'] as List).cast<Map<String, dynamic>>();
    final remoteFreshness = <String, DateTime>{
      for (final entry in remoteEntries) entry['id'] as String: DateTime.parse(entry['freshness'] as String),
    };

    final myIds = <String>{};
    for (final notebook in library.notebooks) {
      myIds.add(notebook.id);
      final theirs = remoteFreshness[notebook.id];
      if (theirs == null) {
        await _sendNotebook(connection, peerId, notebook);
        continue;
      }
      final mine = _freshness(notebook);
      if (mine.isAfter(theirs)) {
        await _sendNotebook(connection, peerId, notebook);
      } else if (mine.isBefore(theirs)) {
        connection.send({'type': 'notebook-request', 'notebookId': notebook.id});
      }
    }
    for (final id in remoteFreshness.keys) {
      if (!myIds.contains(id) && !library.deletedNotebookIds.containsKey(id)) {
        connection.send({'type': 'notebook-request', 'notebookId': id});
      }
    }
  }

  Future<void> _handleNotebookRequest(_PendingLink link, Map<String, dynamic> message) async {
    final peerId = link.peerId;
    final connection = peerId == null ? null : _connections[peerId];
    if (peerId == null || connection == null) return;
    final notebook = _findLocalNotebook(message['notebookId'] as String);
    if (notebook != null) await _sendNotebook(connection, peerId, notebook);
  }

  Future<void> _handleNotebookData(_PendingLink link, Map<String, dynamic> message) async {
    final incoming = Notebook.fromJson(message['notebook'] as Map<String, dynamic>);
    final images = (message['images'] as Map<String, dynamic>?) ?? const {};

    if (images.isNotEmpty && !await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    for (final entry in images.entries) {
      final file = File('${imagesDir.path}/${entry.key}');
      if (!await file.exists()) {
        await file.writeAsBytes(base64Decode(entry.value as String));
      }
    }

    // The incoming filePaths are the sender's own (device-specific)
    // absolute paths - rewrite each to this device's images folder,
    // keyed by filename, which is what ties an ImageElement to the
    // bytes we just wrote (or already had) above.
    for (final section in incoming.sections) {
      for (final page in section.pages) {
        for (final element in page.elements) {
          if (element is ImageElement) {
            element.filePath = '${imagesDir.path}/${_basename(element.filePath)}';
          }
        }
      }
    }

    await library.applySyncedNotebook(incoming);
  }

  /// Pushes the current state of one notebook to every connected peer -
  /// called by LibraryController right after any local edit so changes
  /// propagate immediately while connected, not just at the next
  /// manifest exchange.
  Future<void> pushNotebook(String notebookId) async {
    if (_connections.isEmpty) return;
    final notebook = _findLocalNotebook(notebookId);
    if (notebook == null) return;
    for (final entry in _connections.entries) {
      await _sendNotebook(entry.value, entry.key, notebook);
    }
  }

  /// Pushes a whole-notebook deletion to every connected peer right
  /// away - called by LibraryController.deleteNotebook right after it
  /// happens, same idea as [pushNotebook] for edits. A peer that isn't
  /// connected right now still learns about it eventually, from the
  /// tombstone list included in the next manifest exchange (see
  /// _sendManifest/_handleManifest).
  Future<void> pushNotebookDeletion(String notebookId, DateTime deletedAt) async {
    if (_connections.isEmpty) return;
    final payload = {
      'type': 'notebook-deleted',
      'notebookId': notebookId,
      'deletedAt': deletedAt.toIso8601String(),
    };
    for (final connection in _connections.values) {
      connection.send(payload);
    }
  }

  Future<void> _sendNotebook(SyncConnection connection, String peerId, Notebook notebook) async {
    final basenames = <String>{};
    for (final section in notebook.sections) {
      for (final page in section.pages) {
        for (final element in page.elements) {
          if (element is ImageElement) basenames.add(_basename(element.filePath));
        }
        // Embedded local-file links (NotePage.embeddedLinks) live in
        // this same imagesDir, named the same content-hash way - see
        // LocalStore.importLinkedFile - so they ride along on the same
        // "images" transfer below with no changes needed on the
        // receiving end: _handleNotebookData already writes any
        // basename it doesn't already have, whatever it actually is.
        basenames.addAll(page.embeddedLinks.values);
      }
    }

    final alreadySent = _imagesSentToPeer.putIfAbsent(peerId, () => <String>{});
    final images = <String, String>{};
    for (final name in basenames) {
      if (alreadySent.contains(name)) continue;
      final file = File('${imagesDir.path}/$name');
      if (await file.exists()) {
        images[name] = base64Encode(await file.readAsBytes());
        alreadySent.add(name);
      }
    }

    connection.send({
      'type': 'notebook-data',
      'notebook': notebook.toJson(),
      'images': images,
    });
  }

  String _basename(String filePath) => filePath.substring(filePath.lastIndexOf('/') + 1);
}
