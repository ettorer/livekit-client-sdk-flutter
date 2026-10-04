import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_example/theme.dart';
import 'package:livekit_example/vdi/vdi_session.dart';
import 'package:logging/logging.dart';

import 'pages/connect.dart';

/// `--vdi` keeps this process as the call UI and lets a C++ media engine on
/// the endpoint own WebRTC. Without the flag the example connects as usual.
Future<void> main(List<String> args) async {
  final vdiMode = args.contains('--vdi');
  final format = DateFormat('HH:mm:ss');
  // configure logs for debugging
  Logger.root.level = Level.FINEST;
  Logger.root.onRecord.listen((record) {
    print('${format.format(record.time)} [${record.level.name}]: ${record.message}');
  });

  WidgetsFlutterBinding.ensureInitialized();
  /*if (lkPlatformIsDesktop()) {
    await FlutterWindowClose.setWindowShouldCloseHandler(() async {
      await onWindowShouldClose?.call();
      return true;
    });
  }*/

  /// for livestreaming app, you can initialize the bypassVoiceProcessing = true
  /// here to get better audio quality
  ///
  /// await LiveKitClient.initialize(
  ///  bypassVoiceProcessing: lkPlatformIsMobile(),
  /// );
  if (!vdiMode) {
    await LiveKitClient.initialize(
      zeroPlayoutDelay: true,
      enableWARP: true,
    );
  }
  runApp(LiveKitExampleApp(vdiMode: vdiMode));
}

class LiveKitExampleApp extends StatelessWidget {
  //
  const LiveKitExampleApp({super.key, this.vdiMode = false});

  final bool vdiMode;

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: 'LiveKit Flutter Example',
      theme: LiveKitTheme().buildThemeData(context),
      home: ConnectPage(vdiMode: vdiMode),
    );
    if (!vdiMode) return app;
    return VdiExitScope(child: app);
  }
}
