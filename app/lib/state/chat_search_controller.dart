import 'package:flutter/foundation.dart';

import '../core/api_client.dart';

class SearchHit {
  SearchHit(this.id, this.createdAt);
  final String id;
  final DateTime createdAt;
}

/// Search inside one chat. Results come from the server (message bodies are encrypted at rest,
/// so only the server can match them) newest first; [index] points at the selected one.
class ChatSearchController extends ChangeNotifier {
  ChatSearchController(this.api, this.chatId);

  final ApiClient api;
  final String chatId;

  String query = '';
  List<SearchHit> results = [];
  int total = 0;
  int index = 0;
  bool loading = false;
  String? error;
  int _seq = 0;

  SearchHit? get current => results.isEmpty ? null : results[index];
  bool get hasOlder => index < results.length - 1;
  bool get hasNewer => index > 0;

  /// "3 of 12", "No results", or null while nothing was searched.
  String? get label {
    if (query.isEmpty) return null;
    if (loading && results.isEmpty) return 'Searching…';
    if (error != null) return 'Search failed';
    if (results.isEmpty) return 'No results';
    final more = total > results.length ? '+' : '';
    return '${index + 1} of ${results.length}$more';
  }

  Future<void> search(String text) async {
    final q = text.trim();
    final seq = ++_seq;
    query = q;
    error = null;
    if (q.isEmpty) {
      results = [];
      total = 0;
      index = 0;
      loading = false;
      notifyListeners();
      return;
    }
    loading = true;
    notifyListeners();
    try {
      final data = await api.get('/api/chats/$chatId/search', query: {'q': q});
      if (seq != _seq) return;
      results = [
        for (final r in data['results'] as List)
          SearchHit((r as Map)['id'] as String, DateTime.parse(r['createdAt'] as String).toLocal()),
      ];
      total = (data['total'] as num?)?.toInt() ?? results.length;
      index = 0; // start from the newest match, like most messengers
    } on ApiException catch (e) {
      if (seq != _seq) return;
      error = e.message;
      results = [];
      total = 0;
    } finally {
      if (seq == _seq) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Moves to the next older match.
  void older() {
    if (!hasOlder) return;
    index++;
    notifyListeners();
  }

  /// Moves to the next newer match.
  void newer() {
    if (!hasNewer) return;
    index--;
    notifyListeners();
  }

  void clear() {
    _seq++;
    query = '';
    results = [];
    total = 0;
    index = 0;
    loading = false;
    error = null;
    notifyListeners();
  }
}
