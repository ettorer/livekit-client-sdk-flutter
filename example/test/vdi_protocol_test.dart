import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_example/vdi/chat.dart';
import 'package:livekit_example/vdi/json_rpc.dart';
import 'package:livekit_example/vdi/media_devices.dart';
import 'package:livekit_example/vdi/media_engine_controller.dart';
import 'package:livekit_example/vdi/media_engine_state.dart';
import 'package:livekit_example/vdi/vdi_session.dart';
import 'package:livekit_example/vdi/view_origin.dart';
import 'package:livekit_example/vdi/visible_region.dart';
import 'package:vdi_visible_region/vdi_visible_region.dart';

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

  test('a fully showing widget is one rectangle covering the tile', () {
    const widget = VisibleScreenRect(left: 10, top: 20, right: 330, bottom: 260);
    expect(
      regionsForWidget(widgetScreen: widget, width: 320, height: 240, screenRects: const [widget]),
      const [RegionRect(left: 0, top: 0, right: 320, bottom: 240)],
    );
  });

  test('windows visible regions stay in physical pixels', () {
    // 15 physical pixels of cover on the left. The geometry size is already
    // physical (320 logical * 1.5), so the offset is not divided by 1.5.
    final regions = regionsForWidget(
      widgetScreen: const VisibleScreenRect(left: 200, top: 100, right: 680, bottom: 460),
      width: 480,
      height: 360,
      screenRects: const [VisibleScreenRect(left: 215, top: 100, right: 680, bottom: 460)],
    );
    expect(regions, const [RegionRect(left: 15, top: 0, right: 480, bottom: 360)]);
  });

  test('a covered widget splits into the pieces that remain', () {
    const widget = VisibleScreenRect(left: 100, top: 80, right: 420, bottom: 320);
    final regions = regionsForWidget(
      widgetScreen: widget,
      width: 320,
      height: 240,
      screenRects: const [
        VisibleScreenRect(left: 100, top: 80, right: 420, bottom: 160),
        VisibleScreenRect(left: 100, top: 220, right: 280, bottom: 320),
      ],
    );
    expect(regions, const [
      RegionRect(left: 0, top: 0, right: 320, bottom: 80),
      RegionRect(left: 0, top: 140, right: 180, bottom: 240),
    ]);
  });

  test('a fully covered widget sends no regions', () {
    expect(
      regionsForWidget(
        widgetScreen: const VisibleScreenRect(left: 0, top: 0, right: 100, bottom: 80),
        width: 100,
        height: 80,
        screenRects: const [],
      ),
      isEmpty,
    );
  });

  test('region cache keeps an empty list until the tile size changes', () {
    final cache = RegionCache()..put('remote:bob', width: 320, height: 240, regions: const []);
    expect(cache.forGeometry('remote:bob', 320, 240), isEmpty);
    expect(
      cache.forGeometry('remote:bob', 300, 240),
      const [RegionRect(left: 0, top: 0, right: 300, bottom: 240)],
    );
    cache.retain({'local'});
    expect(
      cache.forGeometry('remote:bob', 320, 240),
      const [RegionRect(left: 0, top: 0, right: 320, bottom: 240)],
    );
  });

  test('geometry is unchanged only when regions match', () {
    const full = RegionRect(left: 0, top: 0, right: 30, bottom: 40);
    const rect = TileRect(x: 1, y: 2, width: 30, height: 40, regions: [full]);
    expect(rect, const TileRect(x: 1, y: 2, width: 30, height: 40, regions: [full]));
    expect(
      rect ==
          const TileRect(
              x: 1, y: 2, width: 30, height: 40, regions: [RegionRect(left: 0, top: 0, right: 10, bottom: 40)]),
      isFalse,
    );
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

  test('parses get_media and badges the default id', () {
    final devices = MediaDeviceSnapshot.fromJson({
      'cameras': [
        {'id': '/dev/video0', 'name': 'Integrated Camera'},
      ],
      'audio_inputs': [
        {'id': 'default: Built-in Microphone', 'name': 'default: Built-in Microphone', 'index': 0},
        {'id': 'Built-in Microphone', 'name': 'Built-in Microphone', 'index': 1},
      ],
      'audio_outputs': [
        {'id': 'Built-in Speaker', 'name': 'Built-in Speaker', 'index': 1},
      ],
      'selected': {
        'camera': '/dev/video0',
        'audio_input': 'Built-in Microphone',
        'audio_output': 'Built-in Speaker',
      },
      'default': {
        'camera': '/dev/video0',
        'audio_input': 'Built-in Microphone',
        'audio_output': 'Built-in Speaker',
      },
      'audio_error': '',
    });

    expect(devices.cameras.single.id, '/dev/video0');
    expect(devices.audioInputs, hasLength(2));
    expect(devices.audioInputs.first.index, 0);
    expect(devices.defaults.camera, '/dev/video0');
    expect(devices.cameras.single.label(defaultId: devices.defaults.camera), 'Integrated Camera (default)');
    expect(
      listedDeviceId(devices.audioInputs, devices.selected.audioInput, devices.defaults.audioInput),
      'Built-in Microphone',
    );
    expect(listedDeviceId(const [], '', ''), isNull);
  });

  test('set_media result keeps the device lists', () {
    const lists = MediaDeviceSnapshot(
      cameras: [EngineMediaDevice(id: '/dev/video0', name: 'Integrated Camera')],
      selected: MediaDeviceChoice(camera: '/dev/video0'),
      defaults: MediaDeviceChoice(camera: '/dev/video0'),
    );
    final update = MediaDeviceSnapshot.fromJson({
      'ok': true,
      'selected': {
        'camera': '/dev/video2',
        'audio_input': 'Built-in Microphone',
        'audio_output': 'Built-in Speaker',
      },
      'default': {
        'camera': '/dev/video0',
        'audio_input': 'Built-in Microphone',
        'audio_output': 'Built-in Speaker',
      },
    });
    final merged = lists.applying(update);
    expect(merged.cameras.single.id, '/dev/video0');
    expect(merged.selected.camera, '/dev/video2');
    expect(merged.defaults.audioOutput, 'Built-in Speaker');
  });
}
