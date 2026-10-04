import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'media_engine_controller.dart';

/// Media-engine window visibility for a Flutter lifecycle change.
///
/// Minimize is [AppLifecycleState.hidden]. Losing focus
/// ([AppLifecycleState.inactive]) while the windows are already shown does not
/// hide them. Restoring a minimized window passes through [inactive] before
/// [resumed], and that transition places the windows again with `set_geometry`.
bool? mediaWindowsHiddenFor(AppLifecycleState state, {required bool currentlyHidden}) {
  if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
    return true;
  }
  if (currentlyHidden && (state == AppLifecycleState.resumed || state == AppLifecycleState.inactive)) {
    return false;
  }
  return null;
}

final _log = Logger('VdiMediaEngine');

/// Remembers the media engine this app session opened so closing the window
/// can stop published media and quit the process.
class VdiSession {
  VdiSession._();

  static final instance = VdiSession._();

  MediaEngineController? _controller;
  String? _engineUrl;
  var _exitStarted = false;
  var _overlayHidden = false;

  void attach(MediaEngineController controller, String engineUrl) {
    _controller = controller;
    _engineUrl = engineUrl;
    if (_overlayHidden) {
      unawaited(controller.setOverlayHidden(true));
    }
  }

  void onAppLifecycle(AppLifecycleState state) {
    if (_exitStarted) return;
    final hidden = mediaWindowsHiddenFor(state, currentlyHidden: _overlayHidden);
    if (hidden == null || hidden == _overlayHidden) return;
    _overlayHidden = hidden;
    final controller = _controller;
    if (controller == null || controller.isShutdown) return;
    unawaited(controller.setOverlayHidden(hidden));
  }

  void detach(MediaEngineController controller) {
    if (identical(_controller, controller)) {
      _controller = null;
    }
  }

  Future<void> quitOnExit() async {
    if (_exitStarted) return;
    _exitStarted = true;
    final current = _controller;
    if (current != null && !current.isQuitting && !current.isShutdown) {
      await current.quitEngine();
      _controller = null;
      return;
    }
    final url = _engineUrl;
    if (url == null || url.isEmpty) return;
    final temporary = MediaEngineController();
    try {
      await temporary.open(url, syncWindows: false);
      await temporary.quitEngine();
    } catch (error) {
      _log.warning('Could not quit the media engine while closing: $error');
      if (!temporary.isQuitting && !temporary.isShutdown) {
        await temporary.quitEngine();
      }
    }
  }
}

/// Listens for the desktop window closing and quits the media engine first.
class VdiExitScope extends StatefulWidget {
  const VdiExitScope({required this.child, super.key});

  final Widget child;

  @override
  State<VdiExitScope> createState() => _VdiExitScopeState();
}

class _VdiExitScopeState extends State<VdiExitScope> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    VdiSession.instance.onAppLifecycle(state);
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await VdiSession.instance.quitOnExit();
    return AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
