import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

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

  /// Chat video: max 20 MB. Camera recordings use a medium quality preset to stay small.
  static Future<LocalAttachment?> pickVideo(ImageSource source) async {
    final file = await _picker.pickVideo(source: source, maxDuration: const Duration(minutes: 3));
    if (file == null) return null;
    final length = await file.length();
    if (length > maxMediaBytes) {
      throw MediaException('Video is too large (${formatBytes(length)}). The limit is 20 MB — try a shorter clip.');
    }
    final bytes = await file.readAsBytes();
    var mime = file.mimeType ?? lookupMimeType(file.name, headerBytes: bytes) ?? 'video/mp4';
    if (!mime.startsWith('video/')) mime = 'video/mp4';
    return LocalAttachment(bytes: bytes, mime: mime, fileName: file.name, path: file.path);
  }
}
