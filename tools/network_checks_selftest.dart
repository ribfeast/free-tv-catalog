// Proves the two network checks still catch what they say they catch:
//
//   check-streams.sh          does an address play? (the weekly sweep, and
//                             every pull request for the addresses it adds)
//   tools/live_version.dart   is a merged change live yet? (after every merge)
//
//   dart tools/network_checks_selftest.dart
//
// Same reasoning as validate_catalog_selftest.dart: a check that has quietly
// stopped checking is worse than none, because its green tick goes on being
// believed. Neither can be proved against the real internet - nobody can order
// up a dead address or a lagging file server on demand - so this starts a small
// web server on this computer only (127.0.0.1: nothing leaves the machine)
// that plays every part: a video that works, one that is gone, one that fails
// once and then works, one that never answers, a live stream, a live stream
// whose picture is gone behind a healthy master playlist, a web page posing as
// a playlist, live addresses that redirect (one to a second server standing
// in for another host), a playlist with Windows line endings, and a
// catalogue whose "version" changes part-way through. Each check is run as a
// separate program, exactly as the workflows run it, and every case must come
// out the way it says.
//
// Needs bash and curl on the PATH (on Windows, run it from Git Bash). About
// 45 seconds, most of it addresses that never answer or answer slowly.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

late final HttpServer _server;
late final String _origin;
late final Directory _temp;

/// A second server, standing in for a CDN edge on another host: a live
/// stream's first address often redirects to one.
late final HttpServer _edge;
late final String _edgeOrigin;

/// How many times each path has been asked for.
final _hits = <String, int>{};

/// What /live/catalog.json serves: one version per request, the last repeated.
var _liveVersions = <int>[7];
var _liveServed = 0;

var _cases = 0;
var _bad = 0;

Future<void> main() async {
  _temp = Directory.systemTemp.createTempSync('network_selftest_');
  _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _origin = 'http://127.0.0.1:${_server.port}';
  _server.listen(_serve);
  _edge = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _edgeOrigin = 'http://127.0.0.1:${_edge.port}';
  _edge.listen(_serveEdge);
  try {
    stdout.writeln('check-streams.sh:');
    await _streamCases();
    stdout.writeln('\ntools/live_version.dart:');
    await _liveCases();
  } finally {
    await _server.close(force: true);
    await _edge.close(force: true);
    _temp.deleteSync(recursive: true);
  }
  stdout.writeln();
  if (_bad > 0) {
    stdout.writeln('SELF-TEST FAILED: $_bad of $_cases cases. A network check '
        'no longer does what it says, so its tick means nothing until fixed.');
    exit(1);
  }
  stdout.writeln('SELF-TEST PASSED: all $_cases cases behaved.');
  exit(0);
}

// ---------------------------------------------------------------------------
// The pretend internet.

const _goodMaster = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n'
    'low/index.m3u8\n';
const _goodMedia = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg1.ts\n'
    '#EXTINF:6,\nseg2.ts\n';
const _deadMaster = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n'
    'gone/index.m3u8\n';

Future<void> _serve(HttpRequest request) async {
  final path = request.uri.path;
  final n = _hits[path] = (_hits[path] ?? 0) + 1;
  final response = request.response;
  try {
    switch (path) {
      case '/v/ok.mp4':
        _reply(response, 200, List<int>.filled(2048, 0));
      case '/v/flaky.mp4':
        _reply(response, n == 1 ? 503 : 200, List<int>.filled(2048, 0));
      case '/v/slow.mp4':
        // Longer than the --timeout the cases give, so it is never received.
        await Future<void>.delayed(const Duration(seconds: 6));
        _reply(response, 200, List<int>.filled(2048, 0));
      case '/l/good.m3u8':
        _reply(response, 200, _goodMaster);
      case '/l/low/index.m3u8':
        _reply(response, 200, _goodMedia);
      case '/b/bad.m3u8':
        _reply(response, 200, _deadMaster);
      case '/p/page.m3u8':
        response.headers.contentType = ContentType.html;
        _reply(response, 200, '<html><body>Sorry, gone.</body></html>');
      case '/live/catalog.json':
        final i = _liveServed < _liveVersions.length
            ? _liveServed
            : _liveVersions.length - 1;
        _liveServed++;
        _reply(response, 200, '{"version": ${_liveVersions[i]}, "channels": []}');
      case '/bom/catalog.json':
        _reply(response, 200,
            [0xEF, 0xBB, 0xBF, ...utf8.encode('{"version": 8, "channels": []}')]);
      case '/r/moved.m3u8':
        // A tokenised entry point: the playlist is really somewhere else, and
        // the address it moves to has a query with a slash in it.
        _redirect(response, '$_origin/l/good.m3u8?token=a/b');
      case '/r/away.m3u8':
        _redirect(response, '$_edgeOrigin/edge/master.m3u8');
      case '/rv/master.m3u8':
        _reply(response, 200,
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\njump/index.m3u8\n');
      case '/rv/jump/index.m3u8':
        _redirect(response, '$_origin/l/low/index.m3u8');
      case '/c/crlf.m3u8':
        _reply(response, 200, _goodMaster.replaceAll('\n', '\r\n'));
      case '/c/low/index.m3u8':
        _reply(response, 200, _goodMedia.replaceAll('\n', '\r\n'));
      default:
        if (path.startsWith('/ok/')) {
          // Every file here plays; one with "lag" in its name takes 3 s to.
          if (path.contains('lag')) {
            await Future<void>.delayed(const Duration(seconds: 3));
          }
          _reply(response, 200, List<int>.filled(2048, 0));
        } else {
          _reply(response, 404, 'Not found');
        }
    }
    await response.close();
  } on Object {
    // The client hung up first (the address that never answers). Expected.
  }
}

/// The other host. Its master playlist names its picture with a "/..."
/// address, which means THIS host - not the one that redirected here.
Future<void> _serveEdge(HttpRequest request) async {
  final response = request.response;
  try {
    switch (request.uri.path) {
      case '/edge/master.m3u8':
        _reply(response, 200,
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n/edge/low/index.m3u8\n');
      case '/edge/low/index.m3u8':
        _reply(response, 200, _goodMedia);
      default:
        _reply(response, 404, 'Not found');
    }
    await response.close();
  } on Object {
    // The client hung up first. Expected.
  }
}

void _redirect(HttpResponse response, String to) {
  response.statusCode = HttpStatus.found;
  response.headers.set(HttpHeaders.locationHeader, to);
}

void _reply(HttpResponse response, int status, Object body) {
  response.statusCode = status;
  if (body is String) {
    response.write(body);
  } else {
    response.add(body as List<int>);
  }
}

String _u(String path) => '$_origin$path';

/// A catalogue holding [urls]: playlists as live channels, files as the items
/// of one scheduled channel - the two places check-streams.sh looks.
String _catalogue(String name, List<String> urls) {
  final files = urls.where((u) => !u.contains('.m3u8')).toList();
  final streams = urls.where((u) => u.contains('.m3u8')).toList();
  final channels = [
    if (files.isNotEmpty)
      {
        'id': 'files',
        'name': 'Files',
        'kind': 'scheduled',
        'schedule': {
          'epoch': '2026-01-01T00:00:00Z',
          'items': [
            for (final u in files) {'title': u, 'url': u, 'seconds': 60},
          ],
        },
      },
    for (var i = 0; i < streams.length; i++)
      {'id': 'live$i', 'name': 'Live $i', 'streamUrl': streams[i]},
  ];
  final file = File('${_temp.path}/$name.json')
    ..writeAsStringSync(const JsonEncoder.withIndent('  ')
        .convert({'version': 1, 'channels': channels}));
  return _slashes(file.path);
}

// ---------------------------------------------------------------------------
// check-streams.sh

Future<void> _streamCases() async {
  final script = _slashes(Platform.script.resolve('../check-streams.sh').toFilePath());
  Future<_Result> streams(List<String> args,
          {Map<String, String>? environment}) =>
      _run('bash', [script, ...args], environment: environment);

  final base = _catalogue('base', [_u('/v/old.mp4')]);
  final mixed = _catalogue('mixed', [
    _u('/v/ok.mp4'),
    _u('/v/gone.mp4'),
    _u('/v/flaky.mp4'),
    _u('/v/slow.mp4'),
    _u('/v/old.mp4'),
    _u('/l/good.m3u8'),
    _u('/b/bad.m3u8'),
    _u('/p/page.m3u8'),
  ]);

  final a = await streams([
    '--catalog', mixed, '--new-since', base,
    '--timeout', '2', '--retries', '1', '--jobs', '3', //
  ]);
  _check('a pull request with dead addresses exits 1', a, a.code == 1);
  _check('says how many addresses are new', a,
      a.out.contains('checking 7 new address(es); the other 1 are already in'));
  _check('a video that plays: OK', a, a.has(r'^OK +ok\.mp4 +\(HTTP 200\)'));
  _check('a missing video: DEAD, HTTP 404, and names its host', a,
      a.has(r'^DEAD +gone\.mp4 +HTTP 404 \(tried 2 times\)  \[host 127\.0\.0\.1\]$'));
  _check('--retries 1 really asks a dead address twice', a,
      _hits['/v/gone.mp4'] == 2);
  _check('a video that fails once, then plays: OK, and says so', a,
      a.has(r'^OK +flaky\.mp4 +\(HTTP 200\) - played on try 2, after: HTTP 503$'));
  _check('an address that never answers: DEAD, "no answer within 2 s"', a,
      a.has(r'^DEAD +slow\.mp4 +no answer within 2 s'));
  _check('a live stream whose picture plays: OK, with its segments', a,
      a.has(r'^OK +good\.m3u8 +\(2 segments\)'));
  _check('a healthy master playlist over a dead picture: DEAD', a,
      a.has(r'^DEAD +bad\.m3u8 +variant HTTP 404'));
  _check('a web page posing as a playlist: DEAD', a,
      a.has(r'^DEAD +page\.m3u8 +master is not a manifest'));
  _check('an address already in the base is not asked for at all', a,
      _hits['/v/old.mp4'] == null && !a.out.contains('old.mp4'));
  _check('the summary counts the dead addresses per host', a,
      a.out.contains('4 of 7 address(es) did not play') &&
          a.has(r'^  127\.0\.0\.1 +4 dead$'));

  final b = await streams([
    '--catalog', _catalogue('alive', [_u('/v/ok.mp4'), _u('/l/good.m3u8')]),
    '--new-since', base, '--timeout', '2', '--retries', '1', //
  ]);
  _check('new addresses that all play: exit 0', b,
      b.code == 0 && b.out.contains('All 2 address(es) played.'));

  final before = _hits.values.fold(0, (sum, n) => sum + n);
  final c = await streams(['--catalog', base, '--new-since', base]);
  _check('nothing new: exit 0 without asking the network anything', c,
      c.code == 0 &&
          c.out.contains('Nothing new to check.') &&
          _hits.values.fold(0, (sum, n) => sum + n) == before);

  final d = await streams(['--catalog', base, '--timeout', '2']);
  _check('without --new-since every address is checked (the weekly sweep)', d,
      d.code == 1 && d.has(r'^DEAD +old\.mp4 +HTTP 404  \[host 127\.0\.0\.1\]$'));
  _check('the weekly sweep asks each address once (no retries by default)', d,
      _hits['/v/old.mp4'] == 1);

  final e = await streams(['--catalog', base, '--timeout', 'soon']);
  _check('a mistyped option: exit 64', e, e.code == 64);
  final f = await streams(
      ['--catalog', base, '--new-since', '${_slashes(_temp.path)}/missing.json']);
  _check('a base file that is not there: exit 64, not "everything is new"', f,
      f.code == 64 && f.out.contains('No such file'));

  // Live streams the way CDNs serve them. Players follow a redirect, so the
  // check must too, and must look for the picture where the playlist MOVED
  // to: next to it, on its host, without its query.
  final g = await streams([
    '--catalog',
    _catalogue('cdn', [
      _u('/r/moved.m3u8'),
      _u('/r/away.m3u8'),
      _u('/rv/master.m3u8'),
      _u('/c/crlf.m3u8'),
      _u('/l/missing.m3u8'),
    ]),
    '--timeout', '2', //
  ]);
  _check('a live address that redirects: OK, picture found where it moved to',
      g, g.has(r'^OK +moved\.m3u8 +\(2 segments\)$'));
  _check('a redirect to another host: a "/..." picture address means that host',
      g, g.has(r'^OK +away\.m3u8 +\(2 segments\)$'));
  _check('a picture playlist that redirects: OK', g,
      g.has(r'^OK +master\.m3u8 +\(2 segments\)$'));
  // This case can only fail on Linux (the GitHub runner): Git Bash's grep on
  // Windows drops the CR by itself, so there the old script passed it too.
  _check('a playlist written with Windows line endings: OK', g,
      g.has(r'^OK +crlf\.m3u8 +\(2 segments\)$'));
  _check('a live stream that is gone: DEAD, HTTP 404 (not "not a manifest")', g,
      g.code == 1 &&
          g.has(r'^DEAD +missing\.m3u8 +HTTP 404  \[host 127\.0\.0\.1\]$'));

  // The pull request's time budget: a whole channel on a host that never
  // answers would otherwise outlast the job and leave no verdict at all.
  final lagging = _catalogue('lagging', [_u('/ok/1-lag.mp4'), _u('/ok/2-next.mp4')]);
  final h = await streams(
      ['--catalog', lagging, '--timeout', '6', '--time-limit', '2']);
  _check('--time-limit: an address not started in time is SKIP, exit 3', h,
      h.code == 3 &&
          h.has(r'^OK +1-lag\.mp4 ') &&
          h.has(r'^SKIP +2-next\.mp4 +not tried') &&
          _hits['/ok/2-next.mp4'] == null &&
          h.out.contains('1 of 2 address(es) were not tried'));

  // "streams checked by hand" in a pull request: the one way past a verdict
  // the owner knows is wrong. It must still NAME what failed.
  final i = await streams([
    '--catalog', _catalogue('accepted', [_u('/v/ok.mp4'), _u('/v/gone.mp4')]),
    '--timeout', '2', '--checked-by-hand', //
  ]);
  _check('--checked-by-hand: a dead address is still named, then let through',
      i,
      i.code == 0 &&
          i.has(r'^DEAD +gone\.mp4 +HTTP 404') &&
          i.has(r'^ACCEPTED: '));
  final j = await streams([
    '--catalog', lagging, '--timeout', '6', '--time-limit', '2',
    '--checked-by-hand', //
  ]);
  _check('--checked-by-hand also lets through what the time limit left untried',
      j, j.code == 0 && j.has(r'^SKIP +2-next\.mp4') && j.has(r'^ACCEPTED: '));

  // A run that loses a result must never read as a pass: without the guard,
  // two missing results out of three would print "All 3 played".
  final k = await streams([
    '--catalog',
    _catalogue('crash', [_u('/ok/a.mp4'), _u('/ok/b.mp4'), _u('/ok/c.mp4')]),
    '--timeout', '2', '--checked-by-hand', //
  ], environment: {'CHECK_STREAMS_SELFTEST_CRASH_AT': '2'});
  _check('a run that misses a result: exit 2 - even with --checked-by-hand', k,
      k.code == 2 && k.out.contains('only 1 of 3 addresses got a result'));
}

// ---------------------------------------------------------------------------
// tools/live_version.dart

Future<void> _liveCases() async {
  final tool = Platform.script.resolve('live_version.dart').toFilePath();
  final live = _u('/live/catalog.json');
  Future<_Result> version(List<String> args, {List<int> serving = const [8]}) {
    _liveVersions = serving;
    _liveServed = 0;
    return _run(Platform.resolvedExecutable, [tool, ...args]);
  }

  final l1 = await version(['--url', live], serving: [7]);
  _check('prints the version the address serves', l1,
      l1.code == 0 && l1.out.contains('The live address serves version 7.'));

  final l2 = await version(
      ['--url', live, '--wait-for', '8', '--every', '1', '--within', '20'],
      serving: [7, 7, 8]);
  _check('waits while the old version is served, then PUBLISHED', l2,
      l2.code == 0 &&
          l2.out.contains('try 2: the live address serves version 7.') &&
          l2.out.contains('PUBLISHED: the live address serves version 8 '
              '(seen on try 3'));

  final l3 = await version(
      ['--url', live, '--wait-for', '9', '--every', '1', '--within', '3']);
  _check('gives up at the deadline: NOT PUBLISHED, exit 1', l3,
      l3.code == 1 &&
          l3.out.contains('NOT PUBLISHED') &&
          l3.out.contains('Last try: the live address serves version 8.'));

  // Every case that waits gives its own short deadline: when the tool is
  // broken, the default (10 minutes) would stall this self-test with it.
  final l4 = await version(
      ['--url', live, '--wait-for', '7', '--every', '1', '--within', '5']);
  _check('a newer version than the one waited for counts as published', l4,
      l4.code == 0 && l4.out.contains('which is newer than 7'));

  final file = File('${_temp.path}/merged.json')
    ..writeAsStringSync('{"version": 8, "channels": []}');
  final l5 = await version(
      ['--url', live, '--wait-for-file', file.path, '--every', '1', '--within', '5']);
  _check('--wait-for-file waits for the version written in that file', l5,
      l5.code == 0 && l5.out.contains('serves version 8 (seen on try 1'));

  final l6 = await version(['--url', _u('/bom/catalog.json')]);
  _check('a live file with a BOM is not a good file: exit 1, says BOM', l6,
      l6.code == 1 && l6.out.contains('starts with a BOM'));

  final l7 = await version(['--url', _u('/nowhere/catalog.json')]);
  _check('an address that answers 404: exit 1, says so', l7,
      l7.code == 1 && l7.out.contains('answered HTTP 404'));

  final l8 = await version(['--url', live, '--wait-for', 'nine']);
  _check('a mistyped option: exit 64', l8, l8.code == 64);
}

// ---------------------------------------------------------------------------

class _Result {
  _Result(this.code, this.out);
  final int code;
  final String out;

  /// True when some line of the output matches [pattern].
  bool has(String pattern) => RegExp(pattern, multiLine: true).hasMatch(out);
}

/// Runs a program WITHOUT blocking: the pretend internet lives in this same
/// program, and a blocking run would stop it answering.
Future<_Result> _run(String executable, List<String> args,
    {Map<String, String>? environment}) async {
  final result = await Process.run(executable, args,
      environment: environment, stdoutEncoding: utf8, stderrEncoding: utf8);
  final out = '${result.stdout}${result.stderr}'.replaceAll('\r\n', '\n');
  return _Result(result.exitCode, out);
}

void _check(String name, _Result result, bool ok) {
  _cases++;
  if (ok) {
    stdout.writeln('  ok   $name');
    return;
  }
  _bad++;
  stdout.writeln('  BAD  $name  <-- exit code ${result.code}; the program said:');
  for (final line in const LineSplitter().convert(result.out).take(14)) {
    stdout.writeln('         | $line');
  }
}

/// bash on Windows reads C:/x/y but not always C:\x\y.
String _slashes(String path) => path.replaceAll(r'\', '/');
