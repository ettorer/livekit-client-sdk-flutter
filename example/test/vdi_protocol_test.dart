import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_example/vdi/chat.dart';
import 'package:livekit_example/vdi/json_rpc.dart';
import 'package:livekit_example/vdi/media_engine_state.dart';
import 'package:livekit_example/vdi/vdi_session.dart';
import 'package:livekit_example/vdi/view_origin.dart';

void main() {
  test('correlates responses by id and forwards events', () async {
    final sent = <String>[];
    final peer = JsonRpcPeer(send: sent.add);
    final events = <Map<String, dynamic>>[];
    final subscription = peer.events.listen(events.add);

    final pending = peer.call('connect', {'url': 'wss://example', 'token': 'jwt'});
    final request = jsonDecode(sent.single) as Map<String, dynamic>;
    expect(request['jsonrpc'], '2.0');
    expect(request['id'], 1);
    expect(request['method'], 'connect');
    expect(request['params'], {'url': 'wss://example', 'token': 'jwt'});

    peer.handleMessage(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'event': 'connected', 'room': 'demo-room', 'identity': 'alice'},
      }),
    );
    peer.handleMessage(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {'ok': true, 'status': 'connecting'},
      }),
    );

    final result = await pending as Map;
    expect(result['status'], 'connecting');
    await Future<void>.delayed(Duration.zero);
    expect(events.single['identity'], 'alice');

    await subscription.cancel();
    peer.close();
  });

  test('surfaces JSON-RPC errors and fails pending calls on close', () async {
    final peer = JsonRpcPeer(send: (_) {});
    final pending = peer.call('get_status');
    peer.handleMessage(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'error': {'code': -32000, 'message': 'already connected'},
      }),
    );

    expect(
      pending,
      throwsA(
        isA<JsonRpcException>().having((error) => error.code, 'code', -32000).having(
              (error) => error.message,
              'message',
              'already connected',
            ),
      ),
    );

    final dropped = peer.call('ping');
    peer.close();
    expect(dropped, throwsStateError);
  });

  test('omits params when a method takes none', () async {
    final sent = <String>[];
    final peer = JsonRpcPeer(send: sent.add);
    final pending = peer.call('start_video');
    final request = jsonDecode(sent.single) as Map<String, dynamic>;
    expect(request.containsKey('params'), isFalse);
    peer.close();
    expect(pending, throwsStateError);
  });

  test('reconciles a stale video list with events that arrived in flight', () {
    final store = VideoWindowStore();
    store.upsert(
      const VideoWindowInfo(
        windowId: 'local',
        type: 'local',
        identity: 'alice',
        x: 0,
        y: 0,
        width: 320,
        height: 240,
        visible: true,
      ),
    );

    const createdDuring = VideoWindowInfo(
      windowId: 'remote:bob',
      type: 'remote',
      identity: 'bob',
      x: 10,
      y: 10,
      width: 480,
      height: 360,
      visible: true,
    );
    store.upsert(createdDuring);
    store.remove('local');

    store.applySnapshot(
      const [
        VideoWindowInfo(
          windowId: 'local',
          type: 'local',
          identity: 'alice',
          x: 1,
          y: 1,
          width: 320,
          height: 240,
          visible: true,
        ),
      ],
      touchedDuring: {'local', 'remote:bob'},
    );

    expect(store.windows.map((window) => window.windowId), ['remote:bob']);
  });

  test('tile geometry stays in GTK application pixels at 150% scale', () {
    const origin = VdiViewOrigin(x: 100, y: 80, scale: 2, devicePixels: false);
    expect(origin.toScreenX(40), 140);
    expect(origin.toScreenY(20), 100);
    expect(origin.toScreenSize(320), 320);
  });

  test('windows tile geometry uses physical pixels', () {
    const origin = VdiViewOrigin(x: 200, y: 100, scale: 1.5, devicePixels: true);
    expect(origin.toScreenX(40), 260);
    expect(origin.toScreenY(20), 130);
    expect(origin.toScreenSize(320), 480);
  });

  test('parses chat payloads from the media engine', () {
    final message = chatMessageFromEvent(
      {
        'event': 'data_received',
        'topic': vdiChatTopic,
        'identity': 'bob',
        'data': '{"id":"m1","text":"hello","senderIdentity":"bob","createdAt":"2026-10-04T09:00:00.000Z"}',
      },
      localIdentity: 'alice',
    );
    expect(message, isNotNull);
    expect(message!.text, 'hello');
    expect(message.senderIdentity, 'bob');
    expect(message.isLocal, isFalse);

    final echo = chatMessageFromEvent(
      {
        'event': 'chat',
        'identity': 'alice',
        'text': 'hi',
        'id': 'm2',
      },
      localIdentity: 'alice',
    );
    expect(echo!.isLocal, isTrue);
    expect(echo.text, 'hi');
  });

  test('minimize hides media windows and restore shows them', () {
    expect(mediaWindowsHiddenFor(AppLifecycleState.inactive, currentlyHidden: false), isNull);
    expect(mediaWindowsHiddenFor(AppLifecycleState.hidden, currentlyHidden: false), isTrue);
    expect(mediaWindowsHiddenFor(AppLifecycleState.inactive, currentlyHidden: true), isFalse);
    expect(mediaWindowsHiddenFor(AppLifecycleState.resumed, currentlyHidden: true), isFalse);
    expect(mediaWindowsHiddenFor(AppLifecycleState.resumed, currentlyHidden: false), isNull);
  });

  test('window_destroyed is idempotent', () {
    final store = VideoWindowStore()..remove('remote:bob');
    expect(store.windows, isEmpty);
    expect(store.remove('remote:bob'), isFalse);
  });
}
