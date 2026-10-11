import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:vdi_visible_region/vdi_visible_region.dart';

import '../exts.dart';
import '../theme.dart';
import '../vdi/chat.dart';
import '../vdi/media_engine_controller.dart';
import '../vdi/media_engine_state.dart';
import '../vdi/vdi_session.dart';
import '../vdi/view_origin.dart';
import '../vdi/visible_region.dart';
import '../widgets/messages_panel.dart';
import '../widgets/vdi_controls.dart';

/// Room screen for `--vdi`.
///
/// Tiles are placeholders. The media engine draws the real video in its own
/// windows, and this page keeps those windows aligned with each tile.
class VdiRoomPage extends StatefulWidget {
  const VdiRoomPage({required this.controller, super.key});

  final MediaEngineController controller;

  @override
  State<VdiRoomPage> createState() => _VdiRoomPageState();
}

class _VdiRoomPageState extends State<VdiRoomPage> {
  final _tileKeys = <String, GlobalKey>{};
  final _regions = RegionCache();
  final _messageCtrl = TextEditingController();
  final List<ExampleRoomMessage> _messages = [];
  Timer? _geometryTimer;
  Timer? _regionTimer;
  var _regionQueryInFlight = false;
  String? _focusedId;
  var _leaving = false;
  var _seenConnected = false;
  var _askedPublish = false;
  var _showMessagesPanel = false;

  MediaEngineController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _seenConnected = _controller.status.isInRoom;
    _controller.onDataReceived = _onDataReceived;
    _controller.addListener(_onChanged);
    _geometryTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      unawaited(_reportGeometry());
    });
    _regionTimer = Timer.periodic(visibleRegionInterval, (_) {
      unawaited(_refreshVisibleRegions());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_refreshVisibleRegions());
      unawaited(_reportGeometry());
      _maybeAskPublish();
    });
  }

  @override
  void dispose() {
    _geometryTimer?.cancel();
    _regionTimer?.cancel();
    _messageCtrl.dispose();
    _controller.onDataReceived = null;
    _controller.removeListener(_onChanged);
    if (!_controller.isShutdown) {
      final controller = _controller;
      unawaited(controller.shutdown().whenComplete(() {
        VdiSession.instance.detach(controller);
      }));
    }
    super.dispose();
  }

  void _onChanged() {
    if (!mounted || _leaving || _controller.isQuitting) return;
    final status = _controller.status;
    if (status.isInRoom) {
      _seenConnected = true;
      _maybeAskPublish();
    } else if (_seenConnected && status.connection == 'disconnected') {
      unawaited(_leave());
      return;
    }

    final ids = _controller.windows.map((window) => window.windowId).toSet();
    if (_focusedId != null && !ids.contains(_focusedId)) {
      _focusedId = null;
    }
    _retainKeys(ids);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_reportGeometry());
    });
  }

  void _retainKeys(Set<String> ids) {
    _tileKeys.removeWhere((id, _) => !ids.contains(id));
    _regions.retain(ids);
    for (final id in ids) {
      _tileKeys.putIfAbsent(id, GlobalKey.new);
    }
  }

  void _maybeAskPublish() {
    if (_askedPublish || !_controller.status.isInRoom) return;
    _askedPublish = true;
    if (_controller.status.video && _controller.status.audio) return;
    unawaited(_run(() async {
      if (!_controller.status.video) await _controller.startVideo();
      if (!mounted) return;
      if (!_controller.status.audio) await _controller.startAudio();
    }));
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _geometryTimer?.cancel();
    _regionTimer?.cancel();
    await _controller.shutdown();
    VdiSession.instance.detach(_controller);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      await context.showErrorDialog(error);
    }
  }

  void _onDataReceived(Map<String, dynamic> event) {
    final message = chatMessageFromEvent(event, localIdentity: _controller.status.identity);
    if (message == null || !mounted) return;
    if (_messages.any((existing) => existing.id == message.id)) return;
    setState(() {
      _messages.add(message);
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageCtrl.text.trim();
    if (text.isEmpty) return;
    final identity = _controller.status.identity.isEmpty ? 'you' : _controller.status.identity;
    final message = ExampleRoomMessage.chat(
      text: text,
      senderIdentity: identity,
      isLocal: true,
    );
    setState(() {
      _messageCtrl.clear();
      _messages.add(message);
    });
    try {
      await _controller.publishData(topic: vdiChatTopic, data: jsonEncode(message.toJson()));
    } catch (error) {
      if (!mounted) return;
      await context.showErrorDialog(error);
    }
  }

  Future<void> _reportGeometry() async {
    if (_leaving || _controller.isQuitting || !mounted) return;
    final origin = await VdiViewLocator.getOrigin() ?? VdiViewOrigin.fallback;
    if (!mounted || _leaving || _controller.isQuitting) return;
    for (final entry in _tileKeys.entries) {
      final sample = _sampleTile(entry.key, entry.value, origin);
      if (sample == null) continue;
      _controller.reportGeometry(
        entry.key,
        TileRect(
          x: sample.x,
          y: sample.y,
          width: sample.width,
          height: sample.height,
          // Same pixel unit as width and height. Windows values are already
          // physical pixels, so the region edges are not divided by
          // devicePixelRatio.
          regions: _regions.forGeometry(entry.key, sample.width, sample.height),
        ),
      );
    }
  }

  Future<void> _refreshVisibleRegions() async {
    if (_regionQueryInFlight || _leaving || _controller.isQuitting || !mounted) return;
    if (VdiSession.instance.overlayHidden) return;
    _regionQueryInFlight = true;
    try {
      final origin = await VdiViewLocator.getOrigin() ?? VdiViewOrigin.fallback;
      if (!mounted || _leaving || _controller.isQuitting || VdiSession.instance.overlayHidden) return;
      final samples = <_TileSample>[];
      for (final entry in _tileKeys.entries) {
        final sample = _sampleTile(entry.key, entry.value, origin);
        if (sample != null) samples.add(sample);
      }
      if (samples.isEmpty) return;
      final view = View.of(context);
      final native = await VdiVisibleRegion.getVisibleRegions(
        viewId: view.viewId,
        devicePixelRatio: view.devicePixelRatio,
        widgets: [
          for (final sample in samples)
            VisibleWidgetBounds(
              left: sample.left,
              top: sample.top,
              right: sample.right,
              bottom: sample.bottom,
            ),
        ],
      );
      if (!mounted || _leaving || _controller.isQuitting || native == null || native.length != samples.length) {
        return;
      }
      for (var index = 0; index < samples.length; index++) {
        final sample = samples[index];
        final result = native[index];
        final bounds = result.bounds;
        _regions.put(
          sample.id,
          width: sample.width,
          height: sample.height,
          regions: bounds == null
              ? const []
              : regionsForWidget(
                  widgetScreen: bounds,
                  width: sample.width,
                  height: sample.height,
                  screenRects: result.rectangles,
                ),
        );
      }
    } finally {
      _regionQueryInFlight = false;
    }
    if (mounted) unawaited(_reportGeometry());
  }

  _TileSample? _sampleTile(String id, GlobalKey key, VdiViewOrigin origin) {
    final tileContext = key.currentContext;
    if (tileContext == null || !tileContext.mounted) return null;
    final box = tileContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    final bottomRight = box.localToGlobal(Offset(box.size.width, box.size.height));
    final size = box.size;
    return _TileSample(
      id: id,
      left: topLeft.dx,
      top: topLeft.dy,
      right: bottomRight.dx,
      bottom: bottomRight.dy,
      x: origin.toScreenX(topLeft.dx),
      y: origin.toScreenY(topLeft.dy),
      width: origin.toScreenSize(size.width),
      height: origin.toScreenSize(size.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _controller.status;
    final windows = _controller.windows;
    _retainKeys(windows.map((window) => window.windowId).toSet());

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_leave());
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _VdiHeader(controller: _controller),
              if (_controller.lastError.isNotEmpty)
                _ErrorBanner(
                  message: _controller.lastError,
                  onDismiss: _controller.clearError,
                ),
              Expanded(child: _buildBody(status, windows)),
              VdiControls(
                audioEnabled: status.audio,
                videoEnabled: status.video,
                busy: _controller.busy,
                showMessagesPanel: _showMessagesPanel,
                onToggleMessages: () {
                  setState(() {
                    _showMessagesPanel = !_showMessagesPanel;
                  });
                },
                onToggleAudio: () {
                  unawaited(_run(status.audio ? _controller.stopAudio : _controller.startAudio));
                },
                onToggleVideo: () {
                  unawaited(_run(status.video ? _controller.stopVideo : _controller.startVideo));
                },
                onDisconnect: () => unawaited(_leave()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(LiveKitStatus status, List<VideoWindowInfo> windows) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stage = LayoutBuilder(
          builder: (context, stageConstraints) {
            if (windows.isEmpty) {
              return _EmptyStage(status: status, link: _controller.link);
            }
            return _buildStage(windows, stageConstraints);
          },
        );
        if (!_showMessagesPanel) return stage;

        final messages = MessagesPanel(
          messages: List.of(_messages),
          controller: _messageCtrl,
          onSend: () => unawaited(_sendMessage()),
          onClose: () {
            setState(() {
              _showMessagesPanel = false;
            });
          },
        );
        final wide = constraints.maxWidth >= 900;
        if (wide) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Row(
              children: [
                Expanded(child: stage),
                const SizedBox(width: 12),
                SizedBox(width: 340, child: messages),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Column(
            children: [
              Expanded(child: stage),
              const SizedBox(height: 12),
              SizedBox(height: 280, child: messages),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStage(List<VideoWindowInfo> windows, BoxConstraints constraints) {
    final focused = _focusedWindow(windows);
    if (focused == null) {
      return _tileGrid(windows, constraints);
    }

    final others = windows.where((window) => window.windowId != focused.windowId).toList();
    final wide = constraints.maxWidth >= constraints.maxHeight;
    final primary = _tile(focused, large: true);
    if (others.isEmpty) {
      return Padding(padding: const EdgeInsets.all(8), child: primary);
    }

    final stripChildren = <Widget>[
      for (var index = 0; index < others.length; index++) ...[
        if (index > 0) const SizedBox(width: 8, height: 8),
        Expanded(child: _tile(others[index])),
      ],
    ];
    final strip = wide ? Column(children: stripChildren) : Row(children: stripChildren);

    return Padding(
      padding: const EdgeInsets.all(8),
      child: wide
          ? Row(
              children: [
                Expanded(child: primary),
                const SizedBox(width: 8),
                SizedBox(width: 240, child: strip),
              ],
            )
          : Column(
              children: [
                Expanded(flex: 3, child: primary),
                const SizedBox(height: 8),
                SizedBox(height: 140, child: strip),
              ],
            ),
    );
  }

  VideoWindowInfo? _focusedWindow(List<VideoWindowInfo> windows) {
    final focusedId = _focusedId;
    if (focusedId == null) return null;
    for (final window in windows) {
      if (window.windowId == focusedId) return window;
    }
    return null;
  }

  Widget _tileGrid(List<VideoWindowInfo> windows, BoxConstraints constraints) {
    final columns = _columnCount(windows.length, constraints.maxWidth);
    final rows = (windows.length / columns).ceil();
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          for (var row = 0; row < rows; row++) ...[
            if (row > 0) const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  for (var column = 0; column < columns; column++) ...[
                    if (column > 0) const SizedBox(width: 8),
                    Expanded(child: _tileAt(windows, row * columns + column)),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  int _columnCount(int count, double width) {
    if (count <= 1) return 1;
    if (count == 2) return width >= 700 ? 2 : 1;
    if (count <= 4) return width >= 700 ? 2 : 1;
    if (count <= 9) return width >= 900 ? 3 : 2;
    return width >= 1100 ? 4 : 3;
  }

  Widget _tileAt(List<VideoWindowInfo> windows, int index) {
    if (index >= windows.length) return const SizedBox.expand();
    return _tile(windows[index]);
  }

  Widget _tile(VideoWindowInfo window, {bool large = false}) {
    final holeKey = _tileKeys.putIfAbsent(window.windowId, GlobalKey.new);
    return _VdiVideoTile(
      window: window,
      holeKey: holeKey,
      large: large,
      audioEnabled: window.isLocal && _controller.status.audio,
      selected: _focusedId == window.windowId,
      onTap: () {
        setState(() {
          _focusedId = _focusedId == window.windowId ? null : window.windowId;
        });
      },
    );
  }
}

class _EmptyStage extends StatelessWidget {
  const _EmptyStage({required this.status, required this.link});

  final LiveKitStatus status;
  final MediaEngineLink link;

  @override
  Widget build(BuildContext context) {
    final String text;
    if (link == MediaEngineLink.disconnected) {
      text = 'Media engine disconnected';
    } else if (link == MediaEngineLink.connecting) {
      text = 'Connecting to the media engine…';
    } else if (!status.isInRoom && status.connection == 'connecting') {
      text = 'Connecting to LiveKit…';
    } else if (!status.isInRoom) {
      text = 'Not connected to LiveKit';
    } else {
      text = 'No video windows yet';
    }
    return Center(
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(color: LKColors.textSecondary),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Material(
        color: LKColors.lkRed.withValues(alpha: 0.15),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: LKColors.lkRed, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(message)),
              IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Dismiss',
              ),
            ],
          ),
        ),
      );
}

class _VdiHeader extends StatelessWidget {
  const _VdiHeader({required this.controller});

  final MediaEngineController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.status;
    final remoteCount = status.remoteParticipants.length;
    final participantCount = status.isInRoom ? remoteCount + 1 : remoteCount;
    final link = controller.link;
    final reconnecting = link != MediaEngineLink.connected;
    final liveKitConnecting = status.connection == 'connecting' || status.connection == 'disconnecting';
    final label = reconnecting
        ? (link == MediaEngineLink.connecting ? 'Media engine' : 'Media engine lost')
        : liveKitConnecting
            ? status.connection
            : (status.isInRoom ? 'Connected' : 'Disconnected');
    final color = status.isInRoom && !reconnecting && !liveKitConnecting ? LKColors.lkGreen : Colors.orange;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: LKColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  status.room.isEmpty ? 'LiveKit Room' : status.room,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (status.identity.isNotEmpty) status.identity,
                    '$participantCount participant${participantCount == 1 ? '' : 's'}',
                    'VDI',
                  ].join(' / '),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: LKColors.textSecondary),
                ),
              ],
            ),
          ),
          _StatusPill(
            label: label,
            icon: status.isInRoom && !reconnecting ? Icons.check_circle : Icons.sync,
            color: color,
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.icon, required this.color});

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          border: Border.all(color: color.withValues(alpha: 0.35)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      );
}

class _TileSample {
  const _TileSample({
    required this.id,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final String id;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final int x;
  final int y;
  final int width;
  final int height;
}

class _VdiVideoTile extends StatelessWidget {
  const _VdiVideoTile({
    required this.window,
    required this.holeKey,
    required this.audioEnabled,
    required this.selected,
    required this.onTap,
    this.large = false,
  });

  final VideoWindowInfo window;
  final GlobalKey holeKey;
  final bool audioEnabled;
  final bool selected;
  final bool large;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: LKColors.cardDark,
          border: Border.all(
            color: selected ? LKColors.lkBlue : LKColors.border,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  // Keep the native video inside the tile stroke. The GTK
                  // window sits above Flutter, so it would cover a border
                  // drawn on the same pixels.
                  padding: EdgeInsets.all(selected ? 2 : 1),
                  child: GestureDetector(
                    onTap: onTap,
                    child: ColoredBox(
                      key: holeKey,
                      color: Colors.black,
                      child: const Center(
                        child: Icon(Icons.videocam_outlined, color: Colors.white24, size: 36),
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                height: large ? 36 : 32,
                color: Colors.black.withValues(alpha: 0.45),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        window.label,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    if (window.isLocal)
                      Icon(
                        audioEnabled ? Icons.mic : Icons.mic_off,
                        size: 16,
                        color: audioEnabled ? Colors.white : Colors.redAccent,
                      ),
                    IconButton(
                      onPressed: onTap,
                      icon: Icon(selected ? Icons.fullscreen_exit : Icons.fullscreen, size: 18),
                      tooltip: selected ? 'Exit focus' : 'Focus',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
