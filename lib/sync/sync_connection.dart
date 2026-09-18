// Thin framing layer over a raw TCP socket: each message is a 4-byte
// big-endian length prefix followed by that many bytes of UTF-8 JSON.
// Everything above this - handshake, pairing approval, manifest
// exchange, page sync - is built on top in sync_engine.dart; this file
// only knows how to turn a Socket into a stream of decoded JSON maps
// and back.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class SyncConnection {
  SyncConnection(this._socket) {
    _subscription = _socket.listen(_onData, onDone: _closeInternal, onError: (_) => _closeInternal());
  }

  final Socket _socket;
  StreamSubscription<Uint8List>? _subscription;
  final List<int> _buffer = [];
  final StreamController<Map<String, dynamic>> _messages = StreamController.broadcast();
  final StreamController<void> _closedController = StreamController.broadcast();
  bool _isClosed = false;

  /// Decoded messages as they arrive, oldest first.
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Fires once, whenever this connection ends - the peer disconnected,
  /// a socket error occurred, or [close] was called locally.
  Stream<void> get onClosed => _closedController.stream;

  bool get isClosed => _isClosed;

  String get remoteAddress => _socket.remoteAddress.address;

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    while (true) {
      if (_buffer.length < 4) return;
      final length =
          (_buffer[0] << 24) | (_buffer[1] << 16) | (_buffer[2] << 8) | _buffer[3];
      if (_buffer.length < 4 + length) return;
      final payload = _buffer.sublist(4, 4 + length);
      _buffer.removeRange(0, 4 + length);
      try {
        final json = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
        _messages.add(json);
      } catch (e) {
        // ignore: avoid_print
        print('SyncConnection: dropped malformed message: $e');
      }
    }
  }

  void send(Map<String, dynamic> message) {
    if (_isClosed) return;
    final payload = utf8.encode(jsonEncode(message));
    final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
    try {
      _socket.add(header.buffer.asUint8List());
      _socket.add(payload);
    } catch (e) {
      // ignore: avoid_print
      print('SyncConnection: send failed, closing: $e');
      _closeInternal();
    }
  }

  Future<void> close() => _closeInternal();

  Future<void> _closeInternal() async {
    if (_isClosed) return;
    _isClosed = true;
    await _subscription?.cancel();
    try {
      await _socket.close();
    } catch (_) {}
    if (!_closedController.isClosed) _closedController.add(null);
    await _messages.close();
    await _closedController.close();
  }
}

/// Listens for incoming connections from peers. Whoever calls
/// [connectToPeer] is the "client" for that connection; whoever
/// receives it here is the "server" - the roles only matter for who
/// dials whom, not for what either side is allowed to do afterwards.
class SyncServer {
  SyncServer(this.port);

  final int port;
  ServerSocket? _serverSocket;

  /// The port actually bound after [start] - normally the same as
  /// [port], but can differ if [port] was 0 (ask the OS to pick one).
  int? get boundPort => _serverSocket?.port;

  Future<Stream<SyncConnection>> start() async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _serverSocket = server;
    return server.map((socket) => SyncConnection(socket));
  }

  Future<void> stop() async {
    await _serverSocket?.close();
    _serverSocket = null;
  }
}

Future<SyncConnection> connectToPeer(
  InternetAddress address,
  int port, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final socket = await Socket.connect(address, port, timeout: timeout);
  return SyncConnection(socket);
}
