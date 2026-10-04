import 'package:flutter/material.dart';

/// Call controls that forward to the remote media engine.
class VdiControls extends StatelessWidget {
  const VdiControls({
    required this.audioEnabled,
    required this.videoEnabled,
    required this.busy,
    required this.onToggleAudio,
    required this.onToggleVideo,
    required this.onDisconnect,
    required this.showMessagesPanel,
    required this.onToggleMessages,
    super.key,
  });

  final bool audioEnabled;
  final bool videoEnabled;
  final bool busy;
  final bool showMessagesPanel;
  final VoidCallback onToggleAudio;
  final VoidCallback onToggleVideo;
  final VoidCallback onDisconnect;
  final VoidCallback onToggleMessages;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            IconButton(
              onPressed: busy ? null : onToggleAudio,
              icon: Icon(audioEnabled ? Icons.mic : Icons.mic_off),
              tooltip: audioEnabled ? 'Mute microphone' : 'Unmute microphone',
            ),
            IconButton(
              onPressed: busy ? null : onToggleVideo,
              icon: Icon(videoEnabled ? Icons.videocam : Icons.videocam_off),
              tooltip: videoEnabled ? 'Stop camera' : 'Start camera',
            ),
            IconButton(
              onPressed: onToggleMessages,
              icon: Icon(
                showMessagesPanel ? Icons.mark_chat_unread : Icons.chat_bubble_outline,
                color: showMessagesPanel ? Theme.of(context).colorScheme.primary : null,
              ),
              tooltip: showMessagesPanel ? 'Hide messages' : 'Show messages',
            ),
            IconButton(
              onPressed: busy ? null : onDisconnect,
              icon: const Icon(Icons.call_end),
              tooltip: 'Disconnect',
              color: Colors.redAccent,
            ),
          ],
        ),
      );
}
