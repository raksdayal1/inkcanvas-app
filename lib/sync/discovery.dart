// LAN discovery: broadcasts "I'm here" over UDP so the Windows and
// Android apps can find each other automatically on the same network -
// whether that's real Wi-Fi or the point-to-point network Android's USB
// tethering creates when the phone is plugged in by cable (tethering
// just gives the PC an IP address, so from here on it's the same plain
// IP networking either way). Manual IP entry (see the sync screen) is
// the fallback for when broadcast can't reach - different subnets, or a
// Wi-Fi network that blocks it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DiscoveredPeer {
  DiscoveredPeer({
    required this.deviceId,
    required this.deviceName,
    required this.address,
    required this.tcpPort,
  }) : lastSeen = DateTime.now();

  final String deviceId;
  final String deviceName;
  final InternetAddress address;
  final int tcpPort;
  final DateTime lastSeen;
}

class PeerDiscovery {
  PeerDiscovery({required this.myDeviceId, required this.myDeviceName, required this.tcpPort});

  static const int broadcastPort = 58732;
  static const _announceInterval = Duration(seconds: 2);
  static const _pruneInterval = Duration(seconds: 2);
  static const _staleAfter = Duration(seconds: 6);

  final String myDeviceId;
  final String myDeviceName;
  final int tcpPort;

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  final Map<String, DiscoveredPeer> _peers = {};
  final StreamController<List<DiscoveredPeer>> _controller = StreamController.broadcast();

  /// The current set of discovered peers, re-emitted whenever it
  /// changes (a new peer seen, or an old one going quiet).
  Stream<List<DiscoveredPeer>> get peers => _controller.stream;

  List<DiscoveredPeer> get currentPeers => _peers.values.toList();

  Future<void> start() async {
    if (_socket != null) return;
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, broadcastPort, reuseAddress: true);
      socket.broadcastEnabled = true;
      socket.listen(_onEvent);
      _socket = socket;
    } catch (e) {
      // Most likely another instance of this app already bound the
      // port on this device, or the platform refused broadcast sockets.
      // Discovery just won't work; manual IP entry still will.
      // ignore: avoid_print
      print('PeerDiscovery: failed to bind UDP socket: $e');
      return;
    }
    _announce();
    _announceTimer = Timer.periodic(_announceInterval, (_) => _announce());
    _pruneTimer = Timer.periodic(_pruneInterval, (_) => _prune());
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    try {
      final json = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
      if (json['type'] != 'na-pustakam-announce') return;
      final deviceId = json['deviceId'] as String;
      if (deviceId == myDeviceId) return; // hearing our own broadcast come back
      _peers[deviceId] = DiscoveredPeer(
        deviceId: deviceId,
        deviceName: json['deviceName'] as String,
        address: datagram.address,
        tcpPort: json['tcpPort'] as int,
      );
      _emit();
    } catch (_) {
      // Some other app's broadcast on the same port; ignore it.
    }
  }

  void _announce() {
    final socket = _socket;
    if (socket == null) return;
    final message = utf8.encode(jsonEncode({
      'type': 'na-pustakam-announce',
      'deviceId': myDeviceId,
      'deviceName': myDeviceName,
      'tcpPort': tcpPort,
    }));
    try {
      socket.send(message, InternetAddress('255.255.255.255'), broadcastPort);
    } catch (e) {
      // ignore: avoid_print
      print('PeerDiscovery: broadcast send failed: $e');
    }
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(_staleAfter);
    final before = _peers.length;
    _peers.removeWhere((_, peer) => peer.lastSeen.isBefore(cutoff));
    if (_peers.length != before) _emit();
  }

  void _emit() => _controller.add(_peers.values.toList());

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _socket?.close();
    _socket = null;
    _peers.clear();
  }
}
