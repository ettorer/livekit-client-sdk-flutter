import 'dart:convert';

import '../widgets/messages_panel.dart';

/// Same topic the non-VDI example uses for room chat.
const vdiChatTopic = 'lk-example-chat';

/// Turns a media-engine chat event into a room message.
///
/// `data_received` carries the raw LiveKit payload (`topic` + UTF-8 `data`).
/// `chat` carries `text` and `identity` directly.
ExampleRoomMessage? chatMessageFromEvent(
  Map<String, dynamic> event, {
  required String localIdentity,
}) {
  final name = event['event'] as String? ?? '';
  if (name == 'chat') {
    final text = event['text'] as String? ?? '';
    if (text.isEmpty) return null;
    final sender = _sender(event);
    return _message(
      id: event['id'] as String?,
      text: text,
      sender: sender,
      createdAt: event['createdAt'] as String?,
      localIdentity: localIdentity,
    );
  }
  if (name != 'data_received') return null;

  final sender = _sender(event);
  final decoded = _decodeData(event['data']);
  if (decoded == null) return null;
  final topic = event['topic'] as String?;
  if (topic != null && topic != vdiChatTopic) {
    return ExampleRoomMessage.system('Data from $sender: $decoded');
  }
  try {
    final payload = jsonDecode(decoded);
    if (payload is Map) {
      final parsed = ExampleRoomMessage.fromJson(Map<String, dynamic>.from(payload));
      return ExampleRoomMessage(
        id: parsed.id,
        text: parsed.text,
        senderIdentity: parsed.senderIdentity,
        createdAt: parsed.createdAt,
        isLocal: _isLocal(parsed.senderIdentity, localIdentity),
      );
    }
  } catch (_) {
    return ExampleRoomMessage.system(decoded);
  }
  return ExampleRoomMessage.system(decoded);
}

String _sender(Map<String, dynamic> event) {
  final identity = event['identity'] ?? event['senderIdentity'] ?? event['participant'];
  if (identity is String && identity.isNotEmpty) return identity;
  return 'unknown';
}

String? _decodeData(Object? data) {
  if (data is String) return data;
  if (data is List) {
    final bytes = data.whereType<int>().toList();
    if (bytes.isEmpty) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }
  return null;
}

ExampleRoomMessage _message({
  required String? id,
  required String text,
  required String sender,
  required String? createdAt,
  required String localIdentity,
}) {
  final now = DateTime.now();
  return ExampleRoomMessage(
    id: id ?? '${now.microsecondsSinceEpoch}-$sender',
    text: text,
    senderIdentity: sender,
    createdAt: DateTime.tryParse(createdAt ?? '') ?? now,
    isLocal: _isLocal(sender, localIdentity),
  );
}

bool _isLocal(String sender, String localIdentity) => localIdentity.isNotEmpty && sender == localIdentity;
