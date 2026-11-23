import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../core/format.dart';

class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({super.key, this.url, this.bytes, this.cacheKey});
  final String? url;
  final Uint8List? bytes;
  final String? cacheKey;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: bytes != null
              ? Image.memory(bytes!)
              : CachedNetworkImage(
                  imageUrl: url!,
                  cacheKey: cacheKey,
                  placeholder: (_, _) => const CircularProgressIndicator(),
                  errorWidget: (_, _, _) => const Text('Could not load the image', style: TextStyle(color: Colors.white)),
                ),
        ),
      ),
    );
  }
}

class VideoViewerScreen extends StatefulWidget {
  const VideoViewerScreen({super.key, required this.url});
  final String url;

  @override
  State<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<VideoViewerScreen> {
  late final VideoPlayerController _c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
  String? _error;

  @override
  void initState() {
    super.initState();
    _c.addListener(() {
      if (mounted) setState(() {});
    });
    _c.initialize().then((_) => _c.play()).catchError((Object e) {
      if (mounted) setState(() => _error = 'Could not play this video');
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white))
            : !v.isInitialized
                ? const CircularProgressIndicator()
                : GestureDetector(
                    onTap: () => v.isPlaying ? _c.pause() : _c.play(),
                    child: AspectRatio(
                      aspectRatio: v.aspectRatio,
                      child: Stack(alignment: Alignment.center, children: [
                        VideoPlayer(_c),
                        if (!v.isPlaying) const Icon(Icons.play_circle_fill, color: Colors.white70, size: 72),
                      ]),
                    ),
                  ),
      ),
      bottomNavigationBar: v.isInitialized
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(children: [
                  Text(formatDuration(v.position.inMilliseconds), style: const TextStyle(color: Colors.white)),
                  Expanded(child: VideoProgressIndicator(_c, allowScrubbing: true, padding: const EdgeInsets.all(12))),
                  Text(formatDuration(v.duration.inMilliseconds), style: const TextStyle(color: Colors.white)),
                ]),
              ),
            )
          : null,
    );
  }
}
