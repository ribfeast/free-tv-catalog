// Which catalogue version is the LIVE address serving - the one every phone
// fetches?
//
//   dart tools/live_version.dart                     print it
//   dart tools/live_version.dart --wait-for 9        wait until it serves 9
//                                                    (or newer); 10 minutes
//                                                    at most
//   dart tools/live_version.dart --wait-for-file catalog.json
//                                                    ...the version written
//                                                    in that file
//
// Options:
//   --url URL        ask another address (the self-test uses a local one)
//   --within S       how long to keep trying, in seconds (default 600)
//   --every S        seconds between tries (default 20)
//
// Exit status: 0 = the live address serves it (published); 1 = it did not in
// time, or the live file could not be read; 64 = the command was typed wrong.
//
// WHY THIS EXISTS
// Merging to main is not the same as publishing. Phones read the file through
// GitHub's file server (raw.githubusercontent.com), which keeps a copy for up
// to 5 minutes ("Cache-Control: max-age=300", seen 2026-09-28), and twice
// already "it is published" was believed when it was not: two channels sat
// finished on a branch for 13 days, and once the live file was unreadable to
// every phone while a screenshot showed channels. So "published" means one
// thing: THIS address was fetched and served the expected "version". The
// validate workflow runs this after every merge, which makes that a machine
// check, and the README's "Roll back" steps use it by hand.
//
// It asks the address exactly as a phone does - no cache-busting - because
// what a phone would be given is the question. Plain Dart, no packages.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const liveUrl = 'https://raw.githubusercontent.com/ribfeast/free-tv-catalog/'
    'refs/heads/main/catalog.json';

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final uri = Uri.parse(options['url'] ?? liveUrl);
  final within = _seconds(options, 'within', 600);
  final every = _seconds(options, 'every', 20);

  int? want;
  if (options.containsKey('wait-for')) {
    want = int.tryParse(options['wait-for']!);
    if (want == null || want < 1) _usage('--wait-for takes a whole number.');
  } else if (options.containsKey('wait-for-file')) {
    want = _versionInFile(options['wait-for-file']!);
  }

  if (want == null) {
    final seen = await _fetch(uri);
    stdout.writeln(
        '${seen.describe[0].toUpperCase()}${seen.describe.substring(1)}');
    exit(seen.version == null ? 1 : 0);
  }

  stdout.writeln('Waiting for $uri to serve version $want '
      '(trying every $every s, for up to ${_duration(within)}).');
  final started = DateTime.now();
  final deadline = started.add(Duration(seconds: within));
  var tries = 0;
  late _Seen seen;
  while (true) {
    tries++;
    seen = await _fetch(uri);
    final served = seen.version;
    if (served != null && served >= want) {
      final waited = _duration(DateTime.now().difference(started).inSeconds);
      stdout.writeln(served == want
          ? 'PUBLISHED: the live address serves version $want '
              '(seen on try $tries, after $waited).'
          : 'PUBLISHED: the live address serves version $served, which is '
              'newer than $want - a later change has gone out on top of it '
              '(seen on try $tries, after $waited).');
      exit(0);
    }
    stdout.writeln('  try $tries: ${seen.describe}');
    if (!DateTime.now().add(Duration(seconds: every)).isBefore(deadline)) break;
    await Future<void>.delayed(Duration(seconds: every));
  }

  stdout
    ..writeln()
    ..writeln('NOT PUBLISHED: after ${_duration(within)} and $tries tries, the '
        'live address is still not serving version $want. Phones are not '
        'being given it.')
    ..writeln('Last try: ${seen.describe}');
  stdout.writeln('GitHub\'s file server normally catches up within 5 minutes. '
      'Run this check again (on GitHub: open the run, "Re-run jobs"); if it '
      'is still red, open $uri in a browser and read "version" at the top.');
  exit(1);
}

/// What one fetch of the live address found.
class _Seen {
  _Seen(this.version, this.describe);
  final int? version;
  final String describe;
}

Future<_Seen> _fetch(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(uri);
    final response =
        await request.close().timeout(const Duration(seconds: 60));
    final bytes = await response
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      return _Seen(null, 'the live address answered HTTP '
          '${response.statusCode}, not the file.');
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return _Seen(null, 'the live file starts with a BOM (an invisible '
          'marker Windows PowerShell adds). An earlier app build read such a '
          'file as NO CHANNELS AT ALL.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      return _Seen(null, 'the live file is not readable JSON (${e.message}). '
          'Phones would show no channels from it.');
    }
    final version = decoded is Map<String, dynamic> ? decoded['version'] : null;
    if (version is! int) {
      return _Seen(null, 'the live file has no whole-number "version" '
          '(found: ${jsonEncode(version)}).');
    }
    return _Seen(version, 'the live address serves version $version.');
  } on Object catch (e) {
    // Network trouble of any kind is a try that did not see the file; the
    // loop tries again until the deadline.
    return _Seen(null, 'could not fetch the live address '
        '(${e.toString().split('\n').first}).');
  } finally {
    client.close(force: true);
  }
}

int _versionInFile(String path) {
  final file = File(path);
  if (!file.existsSync()) _usage('No such file: $path');
  try {
    final decoded = jsonDecode(utf8.decode(file.readAsBytesSync()));
    final version = decoded is Map<String, dynamic> ? decoded['version'] : null;
    if (version is int && version >= 1) return version;
  } on FormatException {
    // Falls through to the message below.
  }
  _usage('$path has no whole-number "version" to wait for.');
}

Map<String, String> _parse(List<String> args) {
  const known = {'url', 'within', 'every', 'wait-for', 'wait-for-file'};
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final name = args[i].startsWith('--') ? args[i].substring(2) : null;
    if (name == null || !known.contains(name) || i + 1 >= args.length) {
      _usage('Not understood: ${args[i]}');
    }
    options[name] = args[++i];
  }
  if (options.containsKey('wait-for') && options.containsKey('wait-for-file')) {
    _usage('Give --wait-for or --wait-for-file, not both.');
  }
  return options;
}

int _seconds(Map<String, String> options, String name, int fallback) {
  final text = options[name];
  if (text == null) return fallback;
  final value = int.tryParse(text);
  if (value == null || value < 1) _usage('--$name takes a whole number of seconds.');
  return value;
}

String _duration(int seconds) => seconds < 120
    ? '$seconds s'
    : '${(seconds / 60).toStringAsFixed(seconds % 60 == 0 ? 0 : 1)} minutes';

Never _usage(String problem) {
  stderr
    ..writeln(problem)
    ..writeln('usage: dart tools/live_version.dart '
        '[--wait-for N | --wait-for-file catalog.json] '
        '[--url URL] [--within SECONDS] [--every SECONDS]');
  exit(64);
}
