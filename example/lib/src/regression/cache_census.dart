import '../model/stats.dart';

/// Condenses the raw `getWebCacheStats` map into the handful of numbers the cache-lifetime cases
/// compare, and renders them on one line for the `HBRESULT` log.
///
/// The raw map nests `Map<Object?, Object?>` and `List<Object?>` straight off the platform channel,
/// so nothing here assumes a static type below the top level. A missing or malformed field yields
/// null in the summary rather than a throw: a census that fails to parse must not abort the case
/// whose timing it was only meant to accompany.
Map<String, Object?> summarizeCacheStats(Map<String, Object?> raw) {
  if (raw.isEmpty) return <String, Object?>{};

  final int? ts = _int(raw['ts']);
  int? httpBytes;
  int? httpFiles;
  int? oldest;
  int? newest;
  int? cacheBytes;
  int? dataBytes;

  final Object? roots = raw['roots'];
  if (roots is List) {
    for (final Object? r in roots) {
      if (r is! Map) continue;
      final String label = r['root']?.toString() ?? '';
      final int? total = _int(r['totalBytes']);
      // Roots are labelled by the platform collector: Android `cache/WebView` and
      // `data/app_webview`; iOS `Library/Caches/...` and `Library/WebKit/...`. iOS reports two
      // cache locations, so these accumulate rather than overwrite.
      if (total != null) {
        if (label.startsWith('cache/') || label.startsWith('Library/Caches')) {
          cacheBytes = (cacheBytes ?? 0) + total;
        } else if (label.startsWith('data/') || label.startsWith('Library/WebKit')) {
          dataBytes = (dataBytes ?? 0) + total;
        }
      }

      final Object? groups = r['groups'];
      if (groups is! Map) continue;
      for (final MapEntry<Object?, Object?> g in groups.entries) {
        // The network cache is the only group whose lifetime question is being asked: Chromium's
        // `Default/HTTP Cache`, or WebKit's `NetworkCache/Version N`.
        final String key = g.key.toString();
        if (!key.contains('HTTP Cache') && !key.contains('NetworkCache')) continue;
        final Object? v = g.value;
        if (v is! Map) continue;
        httpBytes = (httpBytes ?? 0) + (_int(v['bytes']) ?? 0);
        httpFiles = (httpFiles ?? 0) + (_int(v['files']) ?? 0);
        final int? o = _int(v['oldestMtime']);
        final int? n = _int(v['newestMtime']);
        if (o != null && (oldest == null || o < oldest)) oldest = o;
        if (n != null && (newest == null || n > newest)) newest = n;
      }
    }
  }

  final Object? code = raw['codeCache'];
  final int? codeBytes = code is Map ? _int(code['bytes']) : null;

  return <String, Object?>{
    'httpBytes': httpBytes,
    'httpFiles': httpFiles,
    // Ages are measured against the census's own clock, so a skewed host clock cannot distort them.
    'httpNewestAgeS': (ts != null && newest != null) ? (ts - newest) ~/ 1000 : null,
    'httpOldestAgeS': (ts != null && oldest != null) ? (ts - oldest) ~/ 1000 : null,
    'codeBytes': codeBytes,
    'cacheBytes': cacheBytes,
    'dataBytes': dataBytes,
    'truncated': raw['truncated'] == true,
  };
}

/// One-line rendering of [summarizeCacheStats] output.
String formatCensus(Map<String, Object?> s) {
  if (s.isEmpty) return 'census=unavailable';
  String age(Object? seconds) {
    if (seconds is! int) return '-';
    if (seconds < 120) return '${seconds}s';
    if (seconds < 7200) return '${seconds ~/ 60}m';
    if (seconds < 172800) return '${seconds ~/ 3600}h';
    return '${seconds ~/ 86400}d';
  }

  return 'http=${formatBytes(s['httpBytes'])}/${s['httpFiles'] ?? '-'}f '
      'newest=${age(s['httpNewestAgeS'])} oldest=${age(s['httpOldestAgeS'])} '
      'code=${formatBytes(s['codeBytes'])} cacheDir=${formatBytes(s['cacheBytes'])} '
      'dataDir=${formatBytes(s['dataBytes'])}${s['truncated'] == true ? ' TRUNCATED' : ''}';
}

/// One-line rendering of the page-side `libCache` summary: `h` hit, `r` revalidated, `d`
/// download, `o` opaque, then the classification of each heavy file by name.
String formatLibCache(Map<String, Object?> detail) {
  final Object? err = detail['error'];
  if (err != null) return 'lib=error($err)';
  final Object? summary = detail['summary'];
  if (summary is! Map) return 'lib=unavailable';
  final String counts = 'h${summary['hit']}/r${summary['revalidated']}/'
      'd${summary['download']}/o${summary['opaque']}';
  final Object? key = detail['key'];
  final String files = key is Map
      ? key.entries
          .map((MapEntry<Object?, Object?> e) => '${_shortName(e.key.toString())}=${e.value}')
          .join(',')
      : '';
  final String flags = <String>[
    if (summary['capped'] == true) 'CAPPED',
    if (summary['blockedFrames'] is int && (summary['blockedFrames'] as int) > 0)
      'blockedFrames=${summary['blockedFrames']}',
  ].join(' ');
  // Bytes cover everything under /chart/ the page's frames fetched (library and page scripts), not
  // just the library: the platform channel carries one summary, and the page scripts are small.
  final String bytes =
      ' xfer=${formatBytes(summary['bytesTransfer'])}/${formatBytes(summary['bytesDecoded'])}dec';
  return 'lib=$counts$bytes${files.isEmpty ? '' : ' [$files]'}${flags.isEmpty ? '' : ' $flags'}';
}

/// One-line rendering of the plugin's `warmWebCache` report.
String formatWarmReport(Map<String, Object?> r) {
  if (r.isEmpty) return 'warm=no report';
  final bool ok = r['ok'] == true;
  final Object? counts = r['counts'];
  final String c = counts is Map
      ? 'h${counts['hit']}/r${counts['revalidated']}/d${counts['download']}/'
          'o${counts['opaque']}/f${counts['failed']}'
      : '-';
  final Object? errors = r['errors'];
  final String firstError = errors is List && errors.isNotEmpty ? ' firstError=${errors.first}' : '';
  return 'warm ok=$ok${ok ? '' : ' reason=${r['reason']}'} origin=${r['origin'] ?? '-'} '
      'files=${r['files'] ?? '-'} $c '
      'xfer=${formatBytes(r['bytesTransfer'])}/${formatBytes(r['bytesDecoded'])}dec '
      '${r['durationMs'] ?? '-'}ms$firstError';
}

/// `library.47eb07e437b7b06c889a.js` -> `library.js`; the content hash is noise in a log line.
String _shortName(String name) =>
    name.replaceFirstMapped(RegExp(r'\.[0-9a-f]{12,}(?=\.[a-z]+$)'), (Match _) => '');

int? _int(Object? v) => v is num ? v.toInt() : null;
