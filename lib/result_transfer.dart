import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Read-only copy of a recorded mark, independent of either app's storage.
class ResultMark {
  final String code;
  final DateTime time;

  const ResultMark({required this.code, required this.time});
}

class ResultDocument {
  final String name;
  final String surname;
  final int chip;
  final DateTime? start;
  final DateTime finish;
  final List<ResultMark> marks;

  ResultDocument({
    required this.name,
    required this.surname,
    required this.chip,
    required this.start,
    required this.finish,
    required Iterable<ResultMark> marks,
  }) : marks = List.unmodifiable(marks);

  Map<String, dynamic> toJson() => {
    'format': 'orientmark-result',
    'version': 0,
    'name': name,
    'surname': surname,
    'number_chip': chip,
    'start': start?.toUtc().toIso8601String(),
    'finish': finish.toUtc().toIso8601String(),
    'count_cp': marks.length,
    'marks': [
      for (final mark in marks)
        {'code': mark.code, 'time': mark.time.toUtc().toIso8601String()},
    ],
  };

  String encode() => jsonEncode(toJson());

  static ResultDocument decode(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic> ||
        json['format'] != 'orientmark-result' ||
        json['version'] != 0 ||
        json['name'] is! String ||
        json['surname'] is! String ||
        json['number_chip'] is! int ||
        json['marks'] is! List ||
        json['count_cp'] is! int ||
        json['count_cp'] != (json['marks'] as List).length) {
      throw const FormatException('Неверный формат результата');
    }
    DateTime parseTime(dynamic value) {
      if (value is! String || !value.endsWith('Z')) {
        throw const FormatException('Ожидается время UTC');
      }
      return DateTime.parse(value);
    }

    final marks = <ResultMark>[];
    for (final value in json['marks']) {
      if (value is! Map ||
          value['code'] is! String ||
          (value['code'] as String).trim().isEmpty) {
        throw const FormatException('Неверная отметка');
      }
      marks.add(
        ResultMark(code: value['code'], time: parseTime(value['time'])),
      );
    }
    return ResultDocument(
      name: json['name'],
      surname: json['surname'],
      chip: json['number_chip'],
      start: json['start'] == null ? null : parseTime(json['start']),
      finish: parseTime(json['finish']),
      marks: marks,
    );
  }
}

/// OrientMark QR v0: sequential packets repeated by the sender, not BC-UR.
/// Hashes detect corruption; they are not a signature or proof of a result.
class ResultQrEncoder {
  static const chunkBytes = 360;
  static const maxPackets = 1024;
  static const maxFrameLength = 1024;

  static List<String> encode(ResultDocument document) {
    final bytes = utf8.encode(document.encode());
    final total = (bytes.length / chunkBytes).ceil();
    if (total > maxPackets) {
      throw const FormatException('Результат слишком большой для QR-передачи');
    }
    final id = sha256.convert(bytes).toString();
    return List.unmodifiable(
      List.generate(total, (index) {
        final chunk = bytes.sublist(
          index * chunkBytes,
          min((index + 1) * chunkBytes, bytes.length),
        );
        return jsonEncode({
          'qr': 'orientmark',
          'v': 0,
          'id': id,
          'index': index,
          'total': total,
          'bytes': bytes.length,
          'hash': sha256.convert(chunk).toString(),
          'data': base64Encode(chunk),
        });
      }),
    );
  }
}

/// Holds one transfer. Foreign packets never discard the current progress.
class ResultQrAssembler {
  String? _id;
  int _total = 0;
  int _byteCount = 0;
  final Map<int, List<int>> _chunks = {};
  ResultDocument? _result;
  String? _json;

  String? get id => _id;
  int get received => _chunks.length;
  int get total => _total;
  ResultDocument? get result => _result;
  String? get json => _json;
  bool get isComplete => _result != null;

  /// Returns false for duplicates or a different transmission.
  bool add(String frame) {
    if (frame.length > ResultQrEncoder.maxFrameLength) {
      throw const FormatException('QR слишком большой');
    }
    final packet = jsonDecode(frame);
    if (packet is! Map<String, dynamic> ||
        packet['qr'] != 'orientmark' ||
        packet['v'] != 0 ||
        packet['id'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(packet['id']) ||
        packet['index'] is! int ||
        packet['total'] is! int ||
        packet['bytes'] is! int ||
        packet['hash'] is! String ||
        packet['data'] is! String) {
      throw const FormatException('Это не QR результата OrientMark');
    }
    final int total = packet['total'];
    final int index = packet['index'];
    final int byteCount = packet['bytes'];
    if (total < 1 ||
        total > ResultQrEncoder.maxPackets ||
        index < 0 ||
        index >= total ||
        byteCount < 1 ||
        byteCount > ResultQrEncoder.chunkBytes * ResultQrEncoder.maxPackets ||
        total != (byteCount / ResultQrEncoder.chunkBytes).ceil()) {
      throw const FormatException('Неверные параметры пакета');
    }
    final chunk = base64Decode(packet['data']);
    final expectedSize = index == total - 1
        ? byteCount - index * ResultQrEncoder.chunkBytes
        : ResultQrEncoder.chunkBytes;
    if (chunk.length != expectedSize ||
        sha256.convert(chunk).toString() != packet['hash']) {
      throw const FormatException('Повреждённый пакет');
    }
    if (_id != null && packet['id'] != _id) return false;
    if (_id != null && (total != _total || byteCount != _byteCount)) {
      throw const FormatException('Несогласованные параметры передачи');
    }
    if (isComplete || _chunks.containsKey(index)) return false;
    _id = packet['id'];
    _total = total;
    _byteCount = byteCount;
    _chunks[index] = chunk;
    if (received == total) {
      try {
        final bytes = [for (var i = 0; i < total; i++) ..._chunks[i]!];
        if (sha256.convert(bytes).toString() != _id) {
          throw const FormatException(
            'Не совпала контрольная сумма результата',
          );
        }
        final json = utf8.decode(bytes);
        final result = ResultDocument.decode(json);
        _json = json;
        _result = result;
      } catch (_) {
        reset();
        rethrow;
      }
    }
    return true;
  }

  void reset() {
    _id = null;
    _total = 0;
    _byteCount = 0;
    _chunks.clear();
    _result = null;
    _json = null;
  }
}
