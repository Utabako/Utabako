import 'dart:convert';
import 'dart:js_interop';

import 'package:utabako/ui/diagnostics/connections_panel.dart';
import 'package:utabako/ui/diagnostics/diagnostic_logs_panel.dart';
import 'package:web/web.dart' as web;

class LiveDiagnostics {
  LiveDiagnostics() {
    final location = web.window.location;
    final storage = web.window.sessionStorage;
    final hash = location.hash;
    if (hash.isNotEmpty) {
      _token = hash.substring(1);
      storage.setItem('utabako.diagnostics.token', _token);
      web.window.history.replaceState(null, '', '/');
    } else {
      _token = storage.getItem('utabako.diagnostics.token') ?? '';
    }
  }

  late final String _token;
  Map<int, DiagnosticLog> _knownLogs = {};
  List<DiagnosticLog> _logs = const [];

  Future<
    ({
      List<DiagnosticConnection> active,
      List<DiagnosticConnection> closed,
      List<DiagnosticLog> logs,
      String? error,
    })
  >
  snapshot() async {
    final json =
        jsonDecode(await _request('/diagnostics/snapshot'))
            as Map<String, Object?>;
    final logs = <int, DiagnosticLog>{};
    for (final record
        in (json['logs'] as List<Object?>).cast<Map<String, Object?>>()) {
      final sequence = record['sequence'] as int;
      logs[sequence] =
          _knownLogs[sequence] ??
          DiagnosticLog(
            DateTime.fromMillisecondsSinceEpoch(record['time'] as int),
            DiagnosticLogLevel.values.byName(record['level'] as String),
            record['source'] as String,
            record['message'] as String,
          );
    }
    if (_knownLogs.length != logs.length ||
        !_knownLogs.keys.every(logs.containsKey)) {
      _logs = logs.values.toList(growable: false);
    }
    _knownLogs = logs;
    return (
      active: _connections(json['active'] as List<Object?>),
      closed: _connections(json['closed'] as List<Object?>),
      logs: _logs,
      error: json['error'] as String?,
    );
  }

  Future<void> close(String id) async {
    await _request('/diagnostics/close', body: jsonEncode({'id': id}));
  }

  List<DiagnosticConnection> _connections(List<Object?> records) => [
    for (final row in records.cast<Map<String, Object?>>())
      DiagnosticConnection(
        id: row['id'] as String,
        host: row['host'] as String,
        destination: row['destination'] as String,
        source: row['source'] as String,
        outbound: row['outbound'] as String,
        rule: row['rule'] as String,
        chain: (row['chain'] as List<Object?>).cast<String>(),
        protocol: row['protocol'] as String,
        process: row['process'] as String?,
        inbound: row['inbound'] as String,
        startedAt: DateTime.fromMillisecondsSinceEpoch(row['startedAt'] as int),
        closedAt: switch (row['closedAt']) {
          final int epoch => DateTime.fromMillisecondsSinceEpoch(epoch),
          _ => null,
        },
        downloadRate: row['downloadRate'] as int,
        uploadRate: row['uploadRate'] as int,
        downloadBytes: row['downloadBytes'] as int,
        uploadBytes: row['uploadBytes'] as int,
      ),
  ];

  Future<String> _request(String path, {String? body}) async {
    if (_token.isEmpty) throw StateError('请打开本次启动生成的私有诊断链接');
    final abort = web.AbortSignal.timeout(3000);
    final headers = web.Headers();
    headers.set('Authorization', 'Bearer $_token');
    if (body != null) headers.set('Content-Type', 'application/json');
    final request = web.RequestInit(
      method: body == null ? 'GET' : 'POST',
      cache: 'no-store',
      headers: headers,
      body: body?.toJS,
      signal: abort,
    );
    final response = await web.window.fetch(path.toJS, request).toDart;
    final text = (await response.text().toDart).toDart;
    if (!response.ok) throw StateError('${response.status}: ${text.trim()}');
    return text;
  }
}
