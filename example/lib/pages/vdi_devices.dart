import 'dart:async';

import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:flutter/material.dart';
import 'package:vdi_visible_region/vdi_visible_region.dart';

import '../exts.dart';
import '../theme.dart';
import '../vdi/json_rpc.dart';
import '../vdi/media_devices.dart';
import '../vdi/media_engine_controller.dart';
import '../vdi/media_engine_state.dart';
import '../vdi/vdi_session.dart';
import '../vdi/view_origin.dart';
import '../vdi/visible_region.dart';
import 'vdi_room.dart';

/// Camera, microphone, and speaker picker for `--vdi`.
///
/// The media engine owns the devices. This page calls `get_media` and starts
/// `start_preview` on the platform default camera. The engine pushes
/// `window_created` for that preview. This page then sends `set_geometry` for
/// that window id so it covers the preview hole. Changing the camera calls
/// `stop_preview`, then `set_media`, then `start_preview` for the new id.
class VdiDevicesPage extends StatefulWidget {
  const VdiDevicesPage({
    required this.controller,
    required this.url,
    required this.token,
    super.key,
  });

  final MediaEngineController controller;
  final String url;
  final String token;

  @override
  State<VdiDevicesPage> createState() => _VdiDevicesPageState();
}

class _VdiDevicesPageState extends State<VdiDevicesPage> {
  final _previewKey = GlobalKey();
  final _regions = RegionCache();
  Timer? _geometryTimer;
  Timer? _regionTimer;
  var _regionQueryInFlight = false;
  var _busy = false;
  var _loading = true;
  var _handedOff = false;
  var _closed = false;
  var _cameraChange = 0;
  String? _previewCamera;
  String? _cameraId;
  String? _audioInputId;
  String? _audioOutputId;
  MediaDeviceSnapshot _devices = const MediaDeviceSnapshot();

  MediaEngineController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onEngine);
    _geometryTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      unawaited(_reportGeometry());
    });
    _regionTimer = Timer.periodic(visibleRegionInterval, (_) {
      unawaited(_refreshVisibleRegions());
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _geometryTimer?.cancel();
    _regionTimer?.cancel();
    _controller.removeListener(_onEngine);
    if (!_handedOff && !_closed) {
      final controller = _controller;
      unawaited(_release(controller));
    }
    super.dispose();
  }

  /// `window_created` / `window_destroyed` for the preview. Geometry is sent
  /// only after the engine reports the window.
  void _onEngine() {
    if (!mounted || _closed) return;
    _regions.retain(_controller.windows.map((window) => window.windowId).toSet());
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_reportGeometry());
    });
  }

  /// Local window from the latest `window_created`, if the engine has one.
  VideoWindowInfo? get _previewWindow {
    for (final window in _controller.windows) {
      if (window.isLocal) return window;
    }
    return null;
  }

  Future<void> _release(MediaEngineController controller) async {
    try {
      await controller.stopPreview();
    } catch (_) {}
    await controller.shutdown();
    VdiSession.instance.detach(controller);
  }

  Future<void> _load() async {
    try {
      final devices = await _controller.getMedia();
      if (!mounted || _closed) return;
      _apply(devices, selectDefaults: true);
      final preview = devices.defaults.camera;
      if (preview.isNotEmpty) {
        await _controller.startPreview(camera: preview);
        if (!mounted || _closed) {
          try {
            await _controller.stopPreview();
          } catch (_) {}
          return;
        }
        _previewCamera = preview;
      }
    } catch (error) {
      if (!mounted || _closed) return;
      await context.showErrorDialog(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _apply(MediaDeviceSnapshot devices, {bool selectDefaults = false}) {
    final previous = _devices;
    _devices = selectDefaults ? devices : previous.applying(devices);
    _cameraId = listedDeviceId(_devices.cameras, _devices.selected.camera, _devices.defaults.camera);
    _audioInputId = listedDeviceId(
      _devices.audioInputs,
      _devices.selected.audioInput,
      _devices.defaults.audioInput,
    );
    _audioOutputId = listedDeviceId(
      _devices.audioOutputs,
      _devices.selected.audioOutput,
      _devices.defaults.audioOutput,
    );
    setState(() {});
  }

  Future<void> _reloadAfterRejectedId() async {
    try {
      final devices = await _controller.getMedia();
      if (!mounted || _closed) return;
      _apply(devices, selectDefaults: true);
    } catch (error) {
      if (!mounted || _closed) return;
      await context.showErrorDialog(error);
    }
  }

  Future<void> _onCamera(String? id) async {
    if (id == null || id == _cameraId || _busy) return;
    final change = ++_cameraChange;
    setState(() => _cameraId = id);
    try {
      if (_previewCamera != null) {
        try {
          await _controller.stopPreview();
        } catch (_) {}
        if (!mounted || _closed || change != _cameraChange) return;
        _previewCamera = null;
      }
      final updated = await _controller.setMedia(camera: id);
      if (!mounted || _closed || change != _cameraChange) return;
      _apply(updated);
      await _controller.startPreview(camera: id);
      if (!mounted || _closed || change != _cameraChange) return;
      _previewCamera = id;
    } on JsonRpcException catch (error) {
      if (error.code == -32000) await _reloadAfterRejectedId();
      if (!mounted || _closed) return;
      await context.showErrorDialog(error);
    } catch (error) {
      if (!mounted || _closed) return;
      await context.showErrorDialog(error);
    }
  }

  Future<void> _onAudio({String? input, String? output}) async {
    if (_busy) return;
    setState(() {
      if (input != null) _audioInputId = input;
      if (output != null) _audioOutputId = output;
    });
    try {
      final updated = await _controller.setMedia(audioInput: input, audioOutput: output);
      if (!mounted || _closed) return;
      _apply(updated);
    } on JsonRpcException catch (error) {
      if (error.code == -32000) await _reloadAfterRejectedId();
      if (!mounted || _closed) return;
      await context.showErrorDialog(error);
    } catch (error) {
      if (!mounted || _closed) return;
      await context.showErrorDialog(error);
    }
  }

  Future<void> _join() async {
    if (_busy || _closed) return;
    setState(() => _busy = true);
    try {
      if (_cameraId != null || _audioInputId != null || _audioOutputId != null) {
        await _controller.setMedia(
          camera: _cameraId,
          audioInput: _audioInputId,
          audioOutput: _audioOutputId,
        );
      }
      if (_previewCamera != null) {
        try {
          await _controller.stopPreview();
        } catch (_) {}
        _previewCamera = null;
      }
      await _controller.ensureRoom(url: widget.url, token: widget.token);
      if (!mounted || _closed) return;
      _handedOff = true;
      _closed = true;
      _geometryTimer?.cancel();
      _regionTimer?.cancel();
      await Navigator.pushReplacement<void, void>(
        context,
        MaterialPageRoute(builder: (_) => VdiRoomPage(controller: _controller)),
      );
    } catch (error) {
      if (_previewCamera == null && _cameraId != null && _cameraId!.isNotEmpty && mounted && !_closed) {
        try {
          await _controller.startPreview(camera: _cameraId!);
          _previewCamera = _cameraId;
        } catch (_) {}
      }
      if (!mounted || _closed) return;
      await context.showErrorDialog(error);
    } finally {
      if (mounted && !_handedOff) setState(() => _busy = false);
    }
  }

  Future<void> _back() async {
    if (_closed) return;
    _closed = true;
    _geometryTimer?.cancel();
    _regionTimer?.cancel();
    await _release(_controller);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _reportGeometry() async {
    final windowId = _previewWindow?.windowId;
    if (windowId == null || windowId.isEmpty || _closed || _controller.isQuitting || !mounted) return;
    final origin = await VdiViewLocator.getOrigin() ?? VdiViewOrigin.fallback;
    if (!mounted || _closed || _previewWindow?.windowId != windowId) return;
    final sample = _sample(origin);
    if (sample == null) return;
    _controller.reportGeometry(
      windowId,
      TileRect(
        x: sample.x,
        y: sample.y,
        width: sample.width,
        height: sample.height,
        regions: _regions.forGeometry(windowId, sample.width, sample.height),
      ),
    );
  }

  Future<void> _refreshVisibleRegions() async {
    final windowId = _previewWindow?.windowId;
    if (_regionQueryInFlight || windowId == null || windowId.isEmpty || _closed || !mounted) return;
    if (VdiSession.instance.overlayHidden) return;
    _regionQueryInFlight = true;
    try {
      final origin = await VdiViewLocator.getOrigin() ?? VdiViewOrigin.fallback;
      if (!mounted || _closed || _previewWindow?.windowId != windowId || VdiSession.instance.overlayHidden) return;
      final sample = _sample(origin);
      if (sample == null) return;
      final view = View.of(context);
      final native = await VdiVisibleRegion.getVisibleRegions(
        viewId: view.viewId,
        devicePixelRatio: view.devicePixelRatio,
        widgets: [
          VisibleWidgetBounds(left: sample.left, top: sample.top, right: sample.right, bottom: sample.bottom),
        ],
      );
      if (!mounted || _closed || native == null || native.length != 1) return;
      final bounds = native.single.bounds;
      _regions.put(
        windowId,
        width: sample.width,
        height: sample.height,
        regions: bounds == null
            ? const []
            : regionsForWidget(
                widgetScreen: bounds,
                width: sample.width,
                height: sample.height,
                screenRects: native.single.rectangles,
              ),
      );
    } finally {
      _regionQueryInFlight = false;
    }
    if (mounted) unawaited(_reportGeometry());
  }

  _PreviewSample? _sample(VdiViewOrigin origin) {
    final previewContext = _previewKey.currentContext;
    if (previewContext == null || !previewContext.mounted) return null;
    final box = previewContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    final bottomRight = box.localToGlobal(Offset(box.size.width, box.size.height));
    return _PreviewSample(
      left: topLeft.dx,
      top: topLeft.dy,
      right: bottomRight.dx,
      bottom: bottomRight.dy,
      x: origin.toScreenX(topLeft.dx),
      y: origin.toScreenY(topLeft.dy),
      width: origin.toScreenSize(box.size.width),
      height: origin.toScreenSize(box.size.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_back());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Select Devices', style: TextStyle(color: Colors.white)),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _busy ? null : () => unawaited(_back()),
          ),
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ColoredBox(
                      key: _previewKey,
                      color: Colors.black,
                      child: _previewWindow == null
                          ? const Center(child: Icon(Icons.videocam_off, color: LKColors.lkBlue, size: 48))
                          : const SizedBox.expand(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...[
                    _deviceMenu(
                      label: 'Camera',
                      hint: 'No camera',
                      value: _cameraId,
                      devices: _devices.cameras,
                      defaultId: _devices.defaults.camera,
                      onChanged: _onCamera,
                    ),
                    _deviceMenu(
                      label: 'Microphone',
                      hint: 'No microphone',
                      value: _audioInputId,
                      devices: _devices.audioInputs,
                      defaultId: _devices.defaults.audioInput,
                      onChanged: (id) {
                        if (id != null) unawaited(_onAudio(input: id));
                      },
                    ),
                    _deviceMenu(
                      label: 'Speaker',
                      hint: 'No speaker',
                      value: _audioOutputId,
                      devices: _devices.audioOutputs,
                      defaultId: _devices.defaults.audioOutput,
                      onChanged: (id) {
                        if (id != null) unawaited(_onAudio(output: id));
                      },
                    ),
                    if (_devices.audioError.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          _devices.audioError,
                          style: const TextStyle(color: Colors.orange),
                        ),
                      ),
                    ElevatedButton(
                      onPressed: _busy ? null : () => unawaited(_join()),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_busy)
                            const Padding(
                              padding: EdgeInsets.only(right: 10),
                              child: SizedBox(
                                height: 15,
                                width: 15,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              ),
                            ),
                          const Text('Join'),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _deviceMenu({
    required String label,
    required String hint,
    required String? value,
    required List<EngineMediaDevice> devices,
    required String defaultId,
    required ValueChanged<String?> onChanged,
  }) {
    final selected = devices.any((device) => device.id == value) ? value : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(label),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton2<String>(
              isExpanded: true,
              hint: Text(hint),
              value: selected,
              items: [
                for (final device in devices)
                  DropdownMenuItem<String>(
                    value: device.id,
                    child: Text(
                      device.label(defaultId: defaultId),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
              ],
              onChanged: devices.isEmpty || _busy ? null : onChanged,
              buttonStyleData: const ButtonStyleData(
                padding: EdgeInsets.symmetric(horizontal: 16),
                height: 40,
              ),
              menuItemStyleData: const MenuItemStyleData(height: 40),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewSample {
  const _PreviewSample({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
  final int x;
  final int y;
  final int width;
  final int height;
}
