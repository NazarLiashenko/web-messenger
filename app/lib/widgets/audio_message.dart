import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';

/// Inline player for voice messages.
class AudioMessage extends StatefulWidget {
  const AudioMessage({super.key, this.url, this.localPath, this.durationMs, required this.color});

  final String? url;
  final String? localPath;
  final int? durationMs;
  final Color color;

  @override
  State<AudioMessage> createState() => _AudioMessageState();
}

class _AudioMessageState extends State<AudioMessage> {
  final _player = AudioPlayer();
  final _subs = <StreamSubscription>[];
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _loading = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    if (widget.durationMs != null) _duration = Duration(milliseconds: widget.durationMs!);
    _subs
      ..add(_player.onPlayerStateChanged.listen((s) => mounted ? setState(() => _state = s) : null))
      ..add(_player.onPositionChanged.listen((p) => mounted ? setState(() => _position = p) : null))
      ..add(_player.onDurationChanged.listen((d) {
        if (mounted && d > Duration.zero) setState(() => _duration = d);
      }))
      ..add(_player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _position = Duration.zero);
      }));
  }

  Future<void> _toggle() async {
    if (_state == PlayerState.playing) {
      await _player.pause();
      return;
    }
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      if (_state == PlayerState.paused) {
        await _player.resume();
      } else if (widget.url != null) {
        await _player.play(UrlSource(widget.url!));
      } else if (widget.localPath != null && !kIsWeb) {
        await _player.play(DeviceFileSource(widget.localPath!));
      }
    } catch (_) {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration ?? Duration.zero;
    final progress = total.inMilliseconds == 0 ? 0.0 : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final playing = _state == PlayerState.playing;
    return Row(children: [
      IconButton.filled(
        onPressed: _loading ? null : _toggle,
        icon: _loading
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(_error ? Icons.refresh : (playing ? Icons.pause : Icons.play_arrow)),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: progress,
              onChanged: total == Duration.zero || _state == PlayerState.stopped
                  ? null
                  : (v) => _player.seek(Duration(milliseconds: (v * total.inMilliseconds).round())),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _error
                ? 'Playback failed — tap to retry'
                : formatDuration((playing || _position > Duration.zero ? _position : total).inMilliseconds),
            style: TextStyle(fontSize: 12, color: widget.color.withValues(alpha: 0.7)),
          ),
        ]),
      ),
    ]);
  }
}
