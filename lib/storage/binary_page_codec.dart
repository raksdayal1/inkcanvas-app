// Binary encoding for one page's on-disk revision log
// (pages/<pageId>.npbs) - the "OneNote-inspired" storage format: instead
// of JSON-encoding the whole page's element list on every save (what
// pages/<pageId>.dat used to do), each edit appends one small, compact
// binary record (PUT with an element's current full state, or DELETE by
// id) to the end of the file. Replaying every record in order
// reconstructs the page - see [replayPageLog]. This is deliberately NOT
// an attempt at the real [MS-ONESTORE] binary format (object spaces,
// revision manifests/chains, content-addressed blobs) - just borrowing
// its core idea (incremental, append-only revisions instead of
// rewriting everything) in a much simpler shape this app can actually
// own and maintain without a compiler to verify it against.
import 'dart:convert' show utf8;
import 'dart:typed_data';
import 'dart:ui';

import '../models/canvas_element.dart';

/// 'N','P','B','S' + format version 1. Written once at the start of a
/// fresh page log; every record after it is just appended, never
/// rewriting these bytes - see LocalStore's format doc comment.
final Uint8List npbsHeader = Uint8List.fromList([0x4E, 0x50, 0x42, 0x53, 0x01]);

/// Low-level little-endian byte writer backed by a plain growable list -
/// avoids depending on exactly where BytesBuilder lives across Dart/
/// Flutter versions, which isn't something that can be checked here
/// without a compiler.
class BinaryWriter {
  final List<int> _bytes = [];
  final ByteData _scratch = ByteData(8);

  void writeUint8(int v) => _bytes.add(v & 0xFF);

  void writeUint32(int v) {
    _scratch.setUint32(0, v, Endian.little);
    for (var i = 0; i < 4; i++) {
      _bytes.add(_scratch.getUint8(i));
    }
  }

  void writeInt64(int v) {
    _scratch.setInt64(0, v, Endian.little);
    for (var i = 0; i < 8; i++) {
      _bytes.add(_scratch.getUint8(i));
    }
  }

  void writeFloat32(double v) {
    _scratch.setFloat32(0, v, Endian.little);
    for (var i = 0; i < 4; i++) {
      _bytes.add(_scratch.getUint8(i));
    }
  }

  void writeBool(bool v) => writeUint8(v ? 1 : 0);

  void writeBytes(List<int> bytes) => _bytes.addAll(bytes);

  /// uint32-length-prefixed UTF-8 string. Used for every string this
  /// format stores (element ids, text box content, font family, image
  /// paths) - one convention, one reader method ([BinaryReader.readString]).
  void writeString(String s) {
    final encoded = utf8.encode(s);
    writeUint32(encoded.length);
    _bytes.addAll(encoded);
  }

  Uint8List toBytes() => Uint8List.fromList(_bytes);
}

/// Reads back what [BinaryWriter] wrote, from a fixed byte buffer.
/// Throws [FormatException] on running past the end of [_data] rather
/// than silently returning garbage - [replayPageLog] relies on that to
/// detect a truncated trailing record (e.g. a crash mid-write) and stop
/// there, keeping everything successfully replayed so far.
class BinaryReader {
  BinaryReader(this._data) : _view = ByteData.sublistView(_data);

  final Uint8List _data;
  final ByteData _view;
  int _pos = 0;

  /// How many bytes have been consumed so far - callers walking a
  /// sequence of back-to-back records use this to advance to the next
  /// one.
  int get bytesConsumed => _pos;

  void _need(int n) {
    if (_pos + n > _data.length) {
      throw const FormatException('Unexpected end of binary page log data');
    }
  }

  int readUint8() {
    _need(1);
    final v = _view.getUint8(_pos);
    _pos += 1;
    return v;
  }

  int readUint32() {
    _need(4);
    final v = _view.getUint32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int readInt64() {
    _need(8);
    final v = _view.getInt64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  double readFloat32() {
    _need(4);
    final v = _view.getFloat32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  bool readBool() => readUint8() != 0;

  Uint8List readBytes(int n) {
    _need(n);
    final v = Uint8List.sublistView(_data, _pos, _pos + n);
    _pos += n;
    return v;
  }

  String readString() {
    final len = readUint32();
    return utf8.decode(readBytes(len));
  }
}

/// Element-type tag byte stored right after a PUT record's id - lets
/// [decodeElementPayload] know which shape to expect without the id
/// itself carrying any type information.
int elementKindByte(CanvasElement el) => switch (el) {
      InkStrokeElement _ => 0,
      TextBoxElement _ => 1,
      ImageElement _ => 2,
      ShapeElement _ => 3,
    };

/// Encodes everything about [el] EXCEPT its id (the record wrapper
/// already carries that once, in [PageLogRecord]) into a compact binary
/// payload - the binary equivalent of that element's toJson().
Uint8List encodeElementPayload(CanvasElement el) {
  final w = BinaryWriter();
  switch (el) {
    case InkStrokeElement s:
      w.writeInt64(s.createdAt.millisecondsSinceEpoch);
      w.writeUint32(s.color.toARGB32());
      w.writeFloat32(s.strokeWidth);
      w.writeUint8(s.kind == StrokeKind.highlighter ? 1 : 0);
      w.writeUint32(s.points.length);
      for (final p in s.points) {
        w.writeFloat32(p.dx);
        w.writeFloat32(p.dy);
      }
      // Same length as points per InkStrokeElement's own doc comment,
      // but written defensively in case an older/odd record somehow
      // didn't keep them in sync.
      for (var i = 0; i < s.points.length; i++) {
        w.writeFloat32(i < s.pressures.length ? s.pressures[i] : 1.0);
      }
    case TextBoxElement t:
      w.writeInt64(t.createdAt.millisecondsSinceEpoch);
      w.writeFloat32(t.rect.left);
      w.writeFloat32(t.rect.top);
      w.writeFloat32(t.rect.width);
      w.writeFloat32(t.rect.height);
      w.writeUint32(t.color.toARGB32());
      w.writeFloat32(t.fontSize);
      final family = t.fontFamily;
      w.writeBool(family != null);
      if (family != null) w.writeString(family);
      w.writeString(t.text);
    case ImageElement img:
      w.writeInt64(img.createdAt.millisecondsSinceEpoch);
      w.writeFloat32(img.rect.left);
      w.writeFloat32(img.rect.top);
      w.writeFloat32(img.rect.width);
      w.writeFloat32(img.rect.height);
      w.writeString(img.filePath);
      final ar = img.aspectRatio;
      w.writeBool(ar != null);
      if (ar != null) w.writeFloat32(ar);
    case ShapeElement sh:
      w.writeInt64(sh.createdAt.millisecondsSinceEpoch);
      w.writeFloat32(sh.rect.left);
      w.writeFloat32(sh.rect.top);
      w.writeFloat32(sh.rect.width);
      w.writeFloat32(sh.rect.height);
      w.writeUint8(ShapeKind.values.indexOf(sh.kind));
      w.writeUint32(sh.color.toARGB32());
      w.writeFloat32(sh.strokeWidth);
      w.writeBool(sh.filled);
  }
  return w.toBytes();
}

/// Inverse of [encodeElementPayload] + [elementKindByte]: rebuilds the
/// element [id] identifies from its kind byte and payload bytes.
CanvasElement decodeElementPayload(String id, int kindByte, Uint8List payload) {
  final r = BinaryReader(payload);
  switch (kindByte) {
    case 0:
      final createdAt = DateTime.fromMillisecondsSinceEpoch(r.readInt64());
      final color = Color(r.readUint32());
      final strokeWidth = r.readFloat32();
      final kind = r.readUint8() == 1 ? StrokeKind.highlighter : StrokeKind.pen;
      final count = r.readUint32();
      final points = <Offset>[];
      for (var i = 0; i < count; i++) {
        points.add(Offset(r.readFloat32(), r.readFloat32()));
      }
      final pressures = <double>[];
      for (var i = 0; i < count; i++) {
        pressures.add(r.readFloat32());
      }
      return InkStrokeElement(
        id: id,
        createdAt: createdAt,
        points: points,
        pressures: pressures,
        color: color,
        strokeWidth: strokeWidth,
        kind: kind,
      );
    case 1:
      final createdAt = DateTime.fromMillisecondsSinceEpoch(r.readInt64());
      final rect = Rect.fromLTWH(r.readFloat32(), r.readFloat32(), r.readFloat32(), r.readFloat32());
      final color = Color(r.readUint32());
      final fontSize = r.readFloat32();
      final hasFamily = r.readBool();
      final family = hasFamily ? r.readString() : null;
      final text = r.readString();
      return TextBoxElement(
        id: id,
        createdAt: createdAt,
        rect: rect,
        text: text,
        color: color,
        fontSize: fontSize,
        fontFamily: family,
      );
    case 2:
      final createdAt = DateTime.fromMillisecondsSinceEpoch(r.readInt64());
      final rect = Rect.fromLTWH(r.readFloat32(), r.readFloat32(), r.readFloat32(), r.readFloat32());
      final filePath = r.readString();
      final hasAspectRatio = r.readBool();
      final aspectRatio = hasAspectRatio ? r.readFloat32() : null;
      return ImageElement(id: id, createdAt: createdAt, rect: rect, filePath: filePath, aspectRatio: aspectRatio);
    case 3:
      final createdAt = DateTime.fromMillisecondsSinceEpoch(r.readInt64());
      final rect = Rect.fromLTWH(r.readFloat32(), r.readFloat32(), r.readFloat32(), r.readFloat32());
      final kind = ShapeKind.values[r.readUint8()];
      final color = Color(r.readUint32());
      final strokeWidth = r.readFloat32();
      final filled = r.readBool();
      return ShapeElement(id: id, createdAt: createdAt, rect: rect, kind: kind, color: color, strokeWidth: strokeWidth, filled: filled);
    default:
      throw FormatException('Unknown page-log element kind byte: $kindByte');
  }
}

/// One revision-log entry: either "this id now has this full state"
/// (PUT - covers a brand new element AND any edit/move/rotate/resize of
/// an existing one, since either way the current state is written in
/// full) or "this id no longer exists" (DELETE, id only).
class PageLogRecord {
  PageLogRecord.put(this.id, CanvasElement element)
      : isDelete = false,
        kindByte = elementKindByte(element),
        payload = encodeElementPayload(element);

  PageLogRecord.delete(this.id)
      : isDelete = true,
        kindByte = 0,
        payload = Uint8List(0);

  final String id;
  final bool isDelete;
  final int kindByte;
  final Uint8List payload;

  Uint8List encode() {
    final w = BinaryWriter();
    w.writeUint8(isDelete ? 1 : 0);
    w.writeString(id);
    if (!isDelete) {
      w.writeUint8(kindByte);
      w.writeUint32(payload.length);
      w.writeBytes(payload);
    }
    return w.toBytes();
  }
}

/// What replaying a page log produces: the reconstructed elements (in
/// the order they were first added - see the doc comment inside this
/// function for why plain map insertion order already gives the right
/// answer here) plus how many records were actually read, which
/// LocalStore uses as its compaction signal (many more records than
/// live elements means lots of now-superseded history is sitting in the
/// file - see LocalStore's format doc comment).
class PageLogReplayResult {
  PageLogReplayResult(this.elements, this.recordCount);
  final List<CanvasElement> elements;
  final int recordCount;
}

/// Rebuilds a page's element list from its raw .npbs file bytes by
/// replaying every PUT/DELETE record in order. Uses a plain
/// `<String, CanvasElement>{}` map as the working state - Dart's Map
/// preserves *insertion* order and, importantly, re-assigning an
/// EXISTING key's value does not move it - so a PUT for an id already
/// in the map (a move/rotate/resize/text-edit) updates its content
/// without disturbing where it falls in the final iteration order,
/// exactly matching how `page.elements` (a plain ordered list, mutated
/// in place for those same operations) behaves. A PUT for a brand new
/// id appends it at the end, same as `page.elements.add(...)` would.
/// Stops (rather than throwing) on the first record that can't be fully
/// read - a truncated trailing write from a crash mid-append - keeping
/// every record successfully replayed before that point, same
/// don't-lose-what's-readable policy as every other corrupt-file case
/// in LocalStore.
PageLogReplayResult replayPageLog(Uint8List bytes) {
  if (bytes.length < npbsHeader.length) {
    return PageLogReplayResult(const [], 0);
  }
  for (var i = 0; i < npbsHeader.length; i++) {
    if (bytes[i] != npbsHeader[i]) return PageLogReplayResult(const [], 0);
  }
  final state = <String, CanvasElement>{};
  var recordCount = 0;
  var pos = npbsHeader.length;
  while (pos < bytes.length) {
    try {
      final r = BinaryReader(Uint8List.sublistView(bytes, pos));
      final isDelete = r.readUint8() == 1;
      final id = r.readString();
      if (isDelete) {
        state.remove(id);
      } else {
        final kindByte = r.readUint8();
        final payloadLen = r.readUint32();
        final payload = r.readBytes(payloadLen);
        state[id] = decodeElementPayload(id, kindByte, payload);
      }
      pos += r.bytesConsumed;
      recordCount++;
    } catch (_) {
      break;
    }
  }
  return PageLogReplayResult(state.values.toList(), recordCount);
}
