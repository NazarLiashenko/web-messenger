import 'dart:typed_data';

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v as String)?.toLocal();

class InviteRef {
  InviteRef(this.id, this.direction);
  final String id;
  final String direction; // incoming | outgoing
  bool get incoming => direction == 'incoming';
}

class AppUser {
  AppUser({
    required this.id,
    required this.username,
    this.about = '',
    this.avatarUrl,
    this.online = false,
    this.lastSeenAt,
    this.email,
    this.emailVerified,
    this.pendingEmail,
    this.chatId,
    this.invite,
    this.createdAt,
    this.role,
  });

  final String id;
  final String username;
  final String about;
  final String? avatarUrl;
  final bool online;
  final DateTime? lastSeenAt;
  final String? email;
  final bool? emailVerified;
  final String? pendingEmail;
  final String? chatId;
  final InviteRef? invite;
  final DateTime? createdAt;

  /// Role inside a group (`owner` | `member`), only for group member lists.
  final String? role;
  bool get isOwner => role == 'owner';

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as String,
        username: j['username'] as String? ?? '',
        about: j['about'] as String? ?? '',
        avatarUrl: j['avatarUrl'] as String?,
        online: j['online'] as bool? ?? false,
        lastSeenAt: _date(j['lastSeenAt']),
        email: j['email'] as String?,
        emailVerified: j['emailVerified'] as bool?,
        pendingEmail: j['pendingEmail'] as String?,
        chatId: j['chatId'] as String?,
        invite: j['invite'] is Map ? InviteRef(j['invite']['id'] as String, j['invite']['direction'] as String) : null,
        createdAt: _date(j['createdAt']),
        role: j['role'] as String?,
      );

  AppUser copyWith({bool? online, DateTime? lastSeenAt, String? chatId, InviteRef? invite, bool clearInvite = false}) =>
      AppUser(
        id: id,
        username: username,
        about: about,
        avatarUrl: avatarUrl,
        online: online ?? this.online,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        email: email,
        emailVerified: emailVerified,
        pendingEmail: pendingEmail,
        chatId: chatId ?? this.chatId,
        invite: clearInvite ? null : (invite ?? this.invite),
        createdAt: createdAt,
        role: role,
      );

  /// Profile update (`user:updated`) keeping the group role.
  AppUser withProfileOf(AppUser u) => AppUser(
        id: id,
        username: u.username,
        about: u.about,
        avatarUrl: u.avatarUrl,
        online: u.online,
        lastSeenAt: u.lastSeenAt,
        createdAt: u.createdAt,
        role: role,
      );
}

enum MessageStatus { sending, failed, sent, delivered, read }

MessageStatus _status(String? s) => switch (s) {
      'read' => MessageStatus.read,
      'delivered' => MessageStatus.delivered,
      _ => MessageStatus.sent,
    };

class MediaInfo {
  MediaInfo({required this.id, required this.url, required this.mime, required this.size, this.thumbnailUrl});
  final String id;
  final String url;
  final String mime;
  final int size;
  final String? thumbnailUrl; // video preview frame

  factory MediaInfo.fromJson(Map<String, dynamic> j) => MediaInfo(
        id: j['id'] as String,
        url: j['url'] as String,
        mime: j['mime'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        thumbnailUrl: j['thumbnailUrl'] as String?,
      );
}

/// A file picked / recorded on the device that is not uploaded yet.
class LocalAttachment {
  LocalAttachment({required this.bytes, required this.mime, required this.fileName, this.path, this.thumbnail});
  final Uint8List bytes;
  final String mime;
  final String fileName;
  final String? path; // native file path (for local video / audio preview)
  final Uint8List? thumbnail; // JPEG preview frame for videos
  String? uploadedMediaId;
  String? uploadedThumbnailId;
}

class Message {
  Message({
    this.id,
    required this.clientId,
    required this.chatId,
    required this.senderId,
    required this.type,
    this.text,
    this.media,
    this.meta = const {},
    required this.createdAt,
    this.editedAt,
    this.deletedAt,
    this.status = MessageStatus.sent,
    this.local,
    this.uploadProgress,
    this.error,
  });

  String? id; // null until stored on the server
  final String clientId;
  final String chatId;
  final String? senderId;
  final String type; // text | image | video | audio | system (group events)
  String? text;
  MediaInfo? media;
  Map<String, dynamic> meta;
  DateTime createdAt;
  DateTime? editedAt;
  DateTime? deletedAt;
  MessageStatus status;
  LocalAttachment? local;
  double? uploadProgress;
  String? error;
  bool retryOnReconnect = false; // failed because of the network: resend automatically

  bool get isDeleted => deletedAt != null;
  bool get isSystem => type == 'system';
  bool get isPending => status == MessageStatus.sending || status == MessageStatus.failed;
  int? get durationMs => (meta['durationMs'] as num?)?.toInt();

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: j['id'] as String,
        clientId: j['clientId'] as String? ?? j['id'] as String,
        chatId: j['chatId'] as String,
        senderId: j['senderId'] as String?,
        type: j['type'] as String,
        text: j['text'] as String?,
        media: j['media'] is Map ? MediaInfo.fromJson(Map<String, dynamic>.from(j['media'] as Map)) : null,
        meta: j['meta'] is Map ? Map<String, dynamic>.from(j['meta'] as Map) : const {},
        createdAt: _date(j['createdAt']) ?? DateTime.now(),
        editedAt: _date(j['editedAt']),
        deletedAt: _date(j['deletedAt']),
        status: _status(j['status'] as String?),
      );

  /// Status updates only move forward (sent -> delivered -> read).
  void upgradeStatus(MessageStatus s) {
    if (s.index > status.index) status = s;
  }
}

class Chat {
  Chat({
    required this.id,
    this.kind = 'direct',
    this.peer,
    this.title,
    this.members = const [],
    this.myRole,
    this.archived = false,
    this.muted = false,
    this.unreadCount = 0,
    this.lastMessage,
    required this.lastActivityAt,
  });

  final String id;
  final String kind; // direct | group

  /// The other person (direct chats only).
  AppUser? peer;

  /// Group name, members (with roles) and my role (groups only).
  String? title;
  List<AppUser> members;
  String? myRole;

  bool archived;
  bool muted;
  int unreadCount;
  Message? lastMessage;
  DateTime lastActivityAt;

  bool get isGroup => kind == 'group';
  bool get iAmOwner => myRole == 'owner';
  String get name => isGroup ? (title ?? 'Group') : (peer?.username ?? 'Chat');
  AppUser? member(String? userId) => isGroup ? members.where((m) => m.id == userId).firstOrNull : (peer?.id == userId ? peer : null);

  factory Chat.fromJson(Map<String, dynamic> j) => Chat(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? 'direct',
        peer: j['peer'] is Map ? AppUser.fromJson(Map<String, dynamic>.from(j['peer'] as Map)) : null,
        title: j['title'] as String?,
        members: j['members'] is List
            ? (j['members'] as List).map((m) => AppUser.fromJson(Map<String, dynamic>.from(m as Map))).toList()
            : const [],
        myRole: j['myRole'] as String?,
        archived: j['archived'] as bool? ?? false,
        muted: j['muted'] as bool? ?? false,
        unreadCount: (j['unreadCount'] as num?)?.toInt() ?? 0,
        lastMessage: j['lastMessage'] is Map ? Message.fromJson(Map<String, dynamic>.from(j['lastMessage'] as Map)) : null,
        lastActivityAt: _date(j['lastActivityAt']) ?? DateTime.now(),
      );
}

class GroupRef {
  GroupRef({required this.id, required this.title, required this.memberCount});
  final String id;
  final String title;
  final int memberCount;

  factory GroupRef.fromJson(Map<String, dynamic> j) => GroupRef(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Group',
        memberCount: (j['memberCount'] as num?)?.toInt() ?? 0,
      );
}

class Invite {
  Invite({
    required this.id,
    required this.direction,
    required this.status,
    required this.user,
    required this.createdAt,
    this.group,
    this.from,
    this.to,
  });

  final String id;
  final String direction;
  final String status;
  final AppUser user; // the other person
  final DateTime createdAt;

  /// Set for invitations into a group chat.
  final GroupRef? group;
  final AppUser? from;
  final AppUser? to;

  bool get incoming => direction == 'incoming';
  bool get isGroup => group != null;

  factory Invite.fromJson(Map<String, dynamic> j) {
    AppUser? u(String k) => j[k] is Map ? AppUser.fromJson(Map<String, dynamic>.from(j[k] as Map)) : null;
    return Invite(
      id: j['id'] as String,
      direction: j['direction'] as String,
      status: j['status'] as String,
      user: u('user')!,
      createdAt: _date(j['createdAt']) ?? DateTime.now(),
      group: j['group'] is Map ? GroupRef.fromJson(Map<String, dynamic>.from(j['group'] as Map)) : null,
      from: u('from'),
      to: u('to'),
    );
  }
}
