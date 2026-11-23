import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:video_compress/video_compress.dart' as vc;

import '../models/models.dart';
import 'format.dart';

class MediaException implements Exception {
  MediaException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Picks images / videos, compresses images and enforces the size limits before upload.
class MediaPicker {
  static const maxAvatarBytes = 5 * 1024 * 1024;
  static const maxMediaBytes = 20 * 1024 * 1024;
  static final _picker = ImagePicker();

  static String? sniffImage(Uint8List b) {
    if (b.length > 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) return 'image/jpeg';
    if (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) return 'image/png';
    return null;
  }

  static Future<({int width, int height})?> imageSize(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = (width: frame.image.width, height: frame.image.height);
      frame.image.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }

  /// Profile picture: JPEG or PNG only, max 5 MB.
  static Future<LocalAttachment?> pickAvatar(ImageSource source) async {
    final file = await _picker.pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 90);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final mime = sniffImage(bytes);
    if (mime == null) throw MediaException('Only JPEG and PNG images are supported for the profile picture');
    if (bytes.length > maxAvatarBytes) {
      throw MediaException('Profile picture is too large (${formatBytes(bytes.length)}). The limit is 5 MB.');
    }
    return LocalAttachment(bytes: bytes, mime: mime, fileName: mime == 'image/png' ? 'avatar.png' : 'avatar.jpg', path: file.path);
  }

  /// Chat image: resized / re-compressed on the device, max 20 MB after compression.
  static Future<(LocalAttachment, Map<String, dynamic>)?> pickImage(ImageSource source) async {
    final file = await _picker.pickImage(source: source, maxWidth: 2048, maxHeight: 2048, imageQuality: 80);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    if (bytes.length > maxMediaBytes) {
      throw MediaException('Image is too large (${formatBytes(bytes.length)}). The limit is 20 MB.');
    }
    final mime = sniffImage(bytes) ?? file.mimeType ?? lookupMimeType(file.name, headerBytes: bytes) ?? 'image/jpeg';
    final size = await imageSize(bytes);
    return (
      LocalAttachment(bytes: bytes, mime: mime, fileName: file.name, path: file.path),
      {if (size != null) 'width': size.width, if (size != null) 'height': size.height},
    );
  }

  /// Chat video: compressed on the device (H.264, ~960x540), then max 20 MB after compression.
  /// [onCompressing] is called once the file is picked, so the UI can show progress.
  static Future<(LocalAttachment, Map<String, dynamic>)?> pickVideo(ImageSource source,
      {void Function()? onCompressing}) async {
    final file = await _picker.pickVideo(source: source, maxDuration: const Duration(minutes: 5));
    if (file == null) return null;
    final meta = <String, dynamic>{};

    if (kIsWeb) {
      // Browsers have no native transcoder: upload as is, limit still applies.
      final bytes = await file.readAsBytes();
      if (bytes.length > maxMediaBytes) {
        throw MediaException('Video is too large (${formatBytes(bytes.length)}). The limit is 20 MB.');
      }
      var mime = file.mimeType ?? lookupMimeType(file.name, headerBytes: bytes) ?? 'video/mp4';
      if (!mime.startsWith('video/')) mime = 'video/mp4';
      return (LocalAttachment(bytes: bytes, mime: mime, fileName: file.name), meta);
    }

    onCompressing?.call();
    final vc.MediaInfo? info;
    try {
      info = await vc.VideoCompress.compressVideo(
        file.path,
        quality: vc.VideoQuality.Res960x540Quality,
        includeAudio: true,
        deleteOrigin: false,
      );
    } catch (e) {
      throw MediaException('Could not compress this video: $e');
    }
    if (info == null || info.path == null) throw MediaException('Video compression was cancelled');
    final compressed = XFile(info.path!);
    final length = await compressed.length();
    if (length > maxMediaBytes) {
      throw MediaException(
          'Video is still too large after compression (${formatBytes(length)}). The limit is 20 MB — try a shorter clip.');
    }
    if (info.duration != null) meta['durationMs'] = info.duration!.round();
    Uint8List? thumbnail;
    try {
      thumbnail = await vc.VideoCompress.getByteThumbnail(file.path, quality: 70);
    } catch (_) {}
    // The preview frame has the real display orientation (metadata rotation is unreliable).
    final size = thumbnail == null ? null : await imageSize(thumbnail);
    if (size != null) {
      meta['width'] = size.width;
      meta['height'] = size.height;
    } else if ((info.width ?? 0) > 0 && (info.height ?? 0) > 0) {
      meta['width'] = info.width;
      meta['height'] = info.height;
    }
    return (
      LocalAttachment(
        bytes: await compressed.readAsBytes(),
        mime: 'video/mp4',
        fileName: 'video.mp4',
        path: info.path,
        thumbnail: thumbnail,
      ),
      meta,
    );
  }
}
