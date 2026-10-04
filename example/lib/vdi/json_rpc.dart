import 'dart:async';
import 'dart:convert';

/// Failure reported by the media engine (`error` object in a JSON-RPC response).
class JsonRpcException implements Exception {
  const JsonRpcException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => message.isEmpty ? 'JSON-RPC error $code' : message;
}

/// Minimal JSON-RPC 2.0 peer.
///
/// Requests carry an integer [id]. Notifications with `method == "event"` and
/// no [id] are exposed on [events].
class JsonRpcPeer {
  JsonRpcPeer({required this.send});

  final void Function(String message) send;

  final _pending = <int, Completer<dynamic>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  var _nextId = 0;
  var _closed = false;

  Stream<Map<String, dynamic>> get events => _events.stream;

  bool get isClosed => _closed;

  Future<dynamic> call(String method, [Map<String, dynamic>? params]) {
    if (_closed) {
      return Future<dynamic>.error(StateError('JSON-RPC connection is closed'));
    }
    final id = ++_nextId;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      send(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          if (params != null) 'params': params,
        }),
      );
    } catch (error, stackTrace) {
      _pending.remove(id);
      completer.completeError(error, stackTrace);
    }
    return completer.future;
  }

  void handleMessage(dynamic message) {
    if (_closed) return;
    try {
      final decoded = message is String ? jsonDecode(message) : message;
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);
      final id = map['id'];
      if (id == null) {
        _dispatchEvent(map);
        return;
      }
      final requestId = id is int ? id : int.tryParse('$id');
      if (requestId == null) return;
      final completer = _pending.remove(requestId);
      if (completer == null || completer.isCompleted) return;
      if (map.containsKey('error')) {
        completer.completeError(_exceptionFrom(map['error']));
        return;
      }
      completer.complete(map['result']);
    } catch (_) {
      // A single malformed frame must not tear down the socket.
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final pending = List<Completer<dynamic>>.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('JSON-RPC connection closed'));
      }
    }
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
  }

  void _dispatchEvent(Map<String, dynamic> map) {
    if (map['method'] != 'event' || map['params'] is! Map) return;
    if (_events.isClosed) return;
    _events.add(Map<String, dynamic>.from(map['params'] as Map));
  }

  JsonRpcException _exceptionFrom(Object? error) {
    if (error is Map) {
      final code = error['code'];
      final message = error['message'];
      return JsonRpcException(
        code is int ? code : -32603,
        message is String ? message : 'JSON-RPC error',
      );
    }
    return const JsonRpcException(-32603, 'JSON-RPC error');
  }
}
