// Strict checker for catalog.json - the file every install of the app reads.
//
//   dart tools/validate_catalog.dart catalog.json                 check one file
//   dart tools/validate_catalog.dart catalog.json base.json       ...and compare
//                                                                 it with the
//                                                                 version that
//                                                                 is live now
//   add --allow-drop when channels or items are being removed ON PURPOSE
//
// It exits 0 when the file is safe to publish and 1 when it is not, which is
// what lets GitHub block the Merge button (see .github/workflows/validate.yml).
// Warnings never block: they are things a person has to decide about.
//
// WHY THIS EXISTS, AND WHY IT IS A SEPARATE PROGRAM
// Merging to main here is a release: every phone picks the file up within
// minutes. The app's real parser cannot run in this repo - it is Flutter code
// in a private repo - so this is a second, hand-written copy of its rules in
// plain Dart with no packages (nothing to install, nothing to go stale).
//
// A hand-written copy can drift from the original. The defence is that this
// file must always be STRICTLY STRICTER than the app: anything it lets through
// the app must read without losing a single channel or programme. So the app's
// rules are written out below, each next to the stricter rule used here. If the
// app's parser changes, change this table and the checks together.
//
//   THE APP (app/lib/data/catalog.dart,        THIS CHECKER
//   app/lib/models/schedule.dart)
//   ---------------------------------------    ---------------------------------
//   Strips a BOM (an invisible marker some      FAILS on a BOM. An older app
//   Windows tools put at the start of a         build did not strip it and read
//   file), then decodes the JSON. Bad JSON      the whole catalogue as empty.
//   = an empty list, silently.                  FAILS on bad JSON or bad UTF-8.
//
//   Accepts {"channels": [...]} or a bare       Only the object form, and
//   [...] list. Ignores "version".              "version" must be a whole number
//                                               that goes UP whenever the file
//                                               changes (needs the base file).
//
//   Skips, silently, any channel that is        FAILS instead of skipping: a
//   not an object, has no name, or has          channel that vanishes quietly is
//   neither a stream nor a schedule.            the bug this exists to stop.
//
//   A missing id is invented from the           FAILS on a missing or repeated
//   channel's POSITION in the list - so it      id. Favourites and history are
//   changes when the list is reordered.         stored by id.
//   Duplicate ids are not noticed.
//
//   Reads "streamUrl" or "url", "logoUrl"       Only the first spelling of each;
//   or "logo", "epgId"/"tvgId"/"tvg-id".        other keys get a warning. A
//   Any text is accepted as an address.         stream address must be https.
//
//   "kind" is never read.                       Must say "scheduled" exactly
//                                               when there is a schedule, so the
//                                               file says what it means.
//
//   Schedule: "epoch" (the start date a         FAILS if it does not parse, and
//   channel's running order is counted          ALSO if it has no time zone (a
//   from) goes through DateTime.tryParse.       "Z" or "+01:00" ending): without
//   No schedule at all if it fails.             one, Dart reads it as the
//                                               PHONE'S local time, and viewers
//                                               in different countries would see
//                                               different programmes.
//
//   Items: silently drops any that is not       FAILS on every one of those.
//   an object, has an empty title, an           Also FAILS on: an address that is
//   empty url, or "seconds" that is not a       not https, "seconds" written as
//   whole number above zero. It accepts         text or with a decimal point, the
//   "seconds": "107" (text). One surviving      same address twice in a channel,
//   item is enough.                             and fewer than 2 items.
//
//   "credit": blank counts as absent.           FAILS when a channel that is not
//   Nothing requires one.                       on the public-domain list below
//                                               has an item with no credit.
//
//   "aspect"/"year": nonsense is ignored.       FAILS on nonsense.
//
// NOT CHECKED HERE (so nobody assumes it is):
//  * whether an address actually plays - check-streams.sh does that, weekly;
//  * whether "seconds" is the file's true length. A wrong value shifts every
//    later programme for every viewer. It must come from ffprobe (a free tool
//    that reads a video file's true length) or the source's own API when the
//    channel is curated - never from a web page;
//  * whether the rights are really what the credit says. That is the curation
//    record in the app repo (tools/channels/*.json);
//  * a key written twice inside one JSON object: Dart keeps the last, silently.

import 'dart:convert';
import 'dart:io';

/// Channels whose footage is public domain, so their items need no credit.
///
/// HOW THE CHECKER KNOWS A CHANNEL IS CREATIVE COMMONS: it does not try to.
/// The catalogue carries no licence field, and guessing from a credit's wording
/// would be exactly the kind of check that looks clever and proves nothing. So
/// the rule is turned round: EVERY scheduled channel must credit EVERY item,
/// unless its id is on this short list. Creative Commons "Attribution" footage
/// is only licensed on condition the credit is shown, so forgetting one is a
/// licence breach on every phone at once; demanding too many credits costs
/// nothing.
///
/// Adding an id here is a rights decision, not a tidy-up. It belongs in its own
/// pull request, with the reason - today: US federal government works (NASA,
/// NOAA), public domain by statute.
const publicDomainChannelIds = <String>{'nasa', 'ocean'};

/// A channel losing more than this share of its items counts as a sharp drop.
const sharpDropShare = 0.20;

/// Longer than this and "seconds" was probably typed in the wrong unit.
const suspiciouslyLongSeconds = 4 * 60 * 60;

const _topKeys = {'version', 'updated', '_comment', 'channels'};
const _channelKeys = {
  'id', 'name', 'category', 'kind', 'schedule', 'streamUrl', 'logoUrl',
  'epgId', '_comment', //
};
const _scheduleKeys = {'epoch', 'items'};
const _itemKeys = {
  'title', 'url', 'seconds', 'year', 'description', 'credit', 'aspect', //
};

/// Everything found, sorted by how much it matters.
class Findings {
  final failures = <String>[];
  final onAir = <String>[]; // warnings that move what viewers see
  final warnings = <String>[];
  final changes = <String>[];
}

class Item {
  Item(this.title, this.url, this.seconds, this.credit);
  final String title;
  final String url;
  final int seconds;
  final String? credit;
}

class Chan {
  Chan(this.id, this.name);
  final String id;
  final String name;
  String? epochText;
  DateTime? epoch;
  bool scheduled = false;
  final items = <Item>[];

  int get totalSeconds => items.fold(0, (sum, i) => sum + i.seconds);
  String get hours => (totalSeconds / 3600).toStringAsFixed(1);
}

class Catalogue {
  int? version;
  final channels = <Chan>[];
}

void main(List<String> args) {
  final paths = args.where((a) => !a.startsWith('--')).toList();
  final flags = args.where((a) => a.startsWith('--')).toSet();
  final unknown = flags.difference({'--allow-drop'});
  if (paths.isEmpty || paths.length > 2 || unknown.isNotEmpty) {
    stderr.writeln('usage: dart tools/validate_catalog.dart '
        '<catalog.json> [base.json] [--allow-drop]');
    exit(64);
  }

  final found = Findings();
  final bytes = _read(paths[0]);
  final current = check(bytes, found);

  if (paths.length == 2) {
    final baseBytes = _read(paths[1]);
    // The base is what is live now. Its own faults are not this change's
    // doing, so they are thrown away - otherwise a broken main could never be
    // repaired, because the repair would be blamed for the breakage.
    final base = check(baseBytes, Findings());
    if (base == null) {
      found.warnings.add('The base file could not be read as a catalogue, so '
          'nothing was compared with it. (Fine if this change is the repair.)');
    } else if (current != null) {
      compare(
        base,
        current,
        found,
        identical: _sameBytes(bytes, baseBytes),
        allowDrop: flags.contains('--allow-drop'),
      );
    }
  }

  report(paths, current, found, compared: paths.length == 2);
  exit(found.failures.isEmpty ? 0 : 1);
}

List<int> _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('No such file: $path');
    exit(64);
  }
  return file.readAsBytesSync();
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Checks one file on its own. Returns null when it is too broken to describe.
Catalogue? check(List<int> bytes, Findings found) {
  var body = bytes;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    found.failures.add('The file starts with a BOM (an invisible marker that '
        'Windows PowerShell adds when it saves UTF-8). An earlier app build '
        'read a catalogue with one as EMPTY. Save it again without the marker.');
    // Carry on without it, so one run reports everything that is wrong.
    body = bytes.sublist(3);
  }

  final String text;
  try {
    text = utf8.decode(body);
  } on FormatException {
    found.failures.add('The file is not valid UTF-8 text.');
    return null;
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    found.failures.add('The file is not valid JSON: ${e.message} '
        '(near character ${e.offset}).');
    return null;
  }

  if (decoded is! Map<String, dynamic>) {
    found.failures.add('The top level must be an object like '
        '{"version": 1, "channels": [...]}.');
    return null;
  }
  _unknownKeys(decoded, _topKeys, 'the top level', found);

  final catalogue = Catalogue();
  final version = decoded['version'];
  if (version is int && version >= 1) {
    catalogue.version = version;
  } else {
    found.failures.add('"version" must be a whole number, 1 or more '
        '(found: ${jsonEncode(version)}).');
  }

  final channels = decoded['channels'];
  if (channels is! List) {
    found.failures.add('"channels" must be a list.');
    return catalogue;
  }
  if (channels.isEmpty) {
    found.failures.add('"channels" is empty: the app would show nothing.');
  }

  final seenIds = <String>{};
  final seenNames = <String>{};
  for (var i = 0; i < channels.length; i++) {
    final chan = _checkChannel(channels[i], i, seenIds, found);
    if (chan == null) continue;
    catalogue.channels.add(chan);
    if (!seenNames.add(chan.name.toLowerCase())) {
      found.warnings.add('Two channels are both called "${chan.name}".');
    }
  }
  return catalogue;
}

Chan? _checkChannel(Object? raw, int index, Set<String> seenIds, Findings f) {
  final position = 'channel #${index + 1}';
  if (raw is! Map<String, dynamic>) {
    f.failures.add('$position is not an object, so the app would skip it.');
    return null;
  }

  final id = raw['id'];
  final name = raw['name'];
  final where = id is String && id.isNotEmpty ? 'channel "$id"' : position;

  if (id is! String || id.trim().isEmpty) {
    f.failures.add('$position has no "id". The app would invent one from its '
        'position in the list, and favourites would break on the next reorder.');
  } else if (id != id.trim()) {
    f.failures.add('$where: the id has spaces around it.');
  } else if (!seenIds.add(id)) {
    f.failures.add('The id "$id" is used by more than one channel.');
  }

  if (name is! String || name.trim().isEmpty) {
    f.failures.add('$where has no "name", so the app would skip it.');
  }
  _unknownKeys(raw, _channelKeys, where, f);

  final chan = Chan(id is String ? id.trim() : '', name is String ? name : '');

  final stream = raw['streamUrl'];
  final schedule = raw['schedule'];
  final kind = raw['kind'];
  if (stream == null && schedule == null) {
    f.failures.add('$where has neither "streamUrl" nor "schedule": nothing to '
        'play, so the app would skip it.');
  }
  if (stream != null && schedule != null) {
    f.failures.add('$where has both "streamUrl" and "schedule". Pick one.');
  }
  if (stream != null) _checkAddress(stream, '$where: "streamUrl"', f);

  if ((kind == 'scheduled') != (schedule != null)) {
    f.failures.add('$where: "kind" must be "scheduled" exactly when the '
        'channel has a "schedule" (found kind: ${jsonEncode(kind)}).');
  }
  if (schedule != null) _checkSchedule(schedule, chan, where, f);

  return chan.id.isEmpty ? null : chan;
}

void _checkSchedule(Object? raw, Chan chan, String where, Findings f) {
  chan.scheduled = true;
  if (raw is! Map<String, dynamic>) {
    f.failures.add('$where: "schedule" must be an object.');
    return;
  }
  _unknownKeys(raw, _scheduleKeys, '$where: schedule', f);

  final epoch = raw['epoch'];
  final parsed = epoch is String ? DateTime.tryParse(epoch) : null;
  if (parsed == null) {
    f.failures.add('$where: "epoch" (the start date the running order is '
        'counted from) does not parse: ${jsonEncode(epoch)}. '
        'Write it like "2026-08-20T00:00:00Z".');
  } else if (!RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(epoch as String)) {
    f.failures.add('$where: "epoch" $epoch has no time zone. Without a "Z" on '
        'the end each phone reads it in its own local time, and viewers in '
        'different countries would see different programmes.');
  } else {
    chan.epoch = parsed.toUtc();
    chan.epochText = epoch;
  }

  final items = raw['items'];
  if (items is! List) {
    f.failures.add('$where: "items" must be a list.');
    return;
  }
  if (items.length < 2) {
    f.failures.add('$where has ${items.length} item(s). A channel needs at '
        'least 2: a single file on a loop is not a channel, and it is what a '
        'half-finished paste looks like.');
  }

  final needsCredit = !publicDomainChannelIds.contains(chan.id);
  final seenUrls = <String>{};
  for (var i = 0; i < items.length; i++) {
    final item = _checkItem(items[i], '$where, item #${i + 1}', needsCredit, f);
    if (item == null) continue;
    if (!seenUrls.add(item.url)) {
      f.failures.add('$where, item #${i + 1}: the same address appears twice '
          'in this channel (${item.url}).');
    }
    chan.items.add(item);
  }
}

Item? _checkItem(Object? raw, String where, bool needsCredit, Findings f) {
  if (raw is! Map<String, dynamic>) {
    f.failures.add('$where is not an object, so the app would drop it.');
    return null;
  }
  _unknownKeys(raw, _itemKeys, where, f);
  final before = f.failures.length;

  final title = raw['title'];
  if (title is! String || title.trim().isEmpty) {
    f.failures.add('$where has an empty "title", so the app would drop it.');
  }

  final url = raw['url'];
  _checkAddress(url, '$where: "url"', f);

  final seconds = raw['seconds'];
  if (seconds is! int) {
    f.failures.add('$where: "seconds" must be a whole number written as a '
        'number, like 107 - not "107" and not 107.5 '
        '(found: ${jsonEncode(seconds)}).');
  } else if (seconds <= 0) {
    f.failures.add('$where: "seconds" is $seconds. A programme with no length '
        'would stall the channel, so the app would drop it.');
  } else if (seconds > suspiciouslyLongSeconds) {
    f.warnings.add('$where: "seconds" is $seconds, which is over 4 hours. '
        'Is it in the wrong unit?');
  }

  final credit = raw['credit'];
  if (credit != null && (credit is! String || credit.trim().isEmpty)) {
    f.failures.add('$where: "credit" is present but blank.');
  } else if (credit == null && needsCredit) {
    f.failures.add('$where has no "credit". Creative Commons footage is only '
        'licensed on condition the credit is shown on screen. (Channels whose '
        'footage is public domain are listed in publicDomainChannelIds in '
        'tools/validate_catalog.dart.)');
  }

  final aspect = raw['aspect'];
  if (aspect != null && (aspect is! num || !aspect.isFinite || aspect <= 0)) {
    f.failures.add('$where: "aspect" must be a number above zero, like 1.778.');
  }
  final year = raw['year'];
  if (year != null && year is! int) {
    f.failures.add('$where: "year" must be a whole number.');
  }
  final description = raw['description'];
  if (description != null && description is! String) {
    f.failures.add('$where: "description" must be text.');
  }

  if (f.failures.length > before) return null;
  return Item(
    (title as String).trim(),
    url as String,
    seconds as int,
    credit is String ? credit.trim() : null,
  );
}

void _checkAddress(Object? raw, String where, Findings f) {
  if (raw is! String || raw.isEmpty) {
    f.failures.add('$where is missing or empty.');
    return;
  }
  final uri = Uri.tryParse(raw);
  if (!raw.startsWith('https://') || uri == null || uri.host.isEmpty) {
    f.failures.add('$where must be an https:// address (found: $raw). Plain '
        'http is blocked on iPhones and can be tampered with on the way.');
  } else if (raw.contains(RegExp(r'\s'))) {
    f.failures.add('$where contains a space or line break: $raw');
  }
}

void _unknownKeys(
  Map<String, dynamic> map,
  Set<String> known,
  String where,
  Findings f,
) {
  for (final key in map.keys) {
    if (!known.contains(key)) {
      f.warnings.add('$where: the app does not read "$key". A typo?');
    }
  }
}

/// Compares the new file with what is live now.
void compare(
  Catalogue base,
  Catalogue current,
  Findings f, {
  required bool identical,
  required bool allowDrop,
}) {
  if (identical) {
    f.changes.add('catalog.json is byte-for-byte the same as the base, so '
        'there is nothing to compare and "version" may stay as it is.');
    return;
  }

  final was = base.version;
  final now = current.version;
  if (was != null && now != null) {
    if (now > was) {
      f.changes.add('version $was -> $now');
    } else {
      f.failures.add('"version" did not go up (base $was, this file $now) but '
          'the file changed. Raise it by one: the number is how anyone can '
          'tell which catalogue a phone, or the live address, is serving.');
    }
  }

  final drops = <String>[];
  final before = {for (final c in base.channels) c.id: c};
  final after = {for (final c in current.channels) c.id: c};

  for (final old in base.channels) {
    final chan = after[old.id];
    if (chan == null) {
      drops.add('Channel "${old.id}" (${old.name}, ${old.items.length} items) '
          'is REMOVED. Anyone who had it as a favourite loses it.');
      continue;
    }
    final lost = old.items.length - chan.items.length;
    if (old.items.isNotEmpty && lost > old.items.length * sharpDropShare) {
      drops.add('Channel "${old.id}" falls from ${old.items.length} to '
          '${chan.items.length} items.');
    }
    _compareChannel(old, chan, f);
  }
  for (final chan in current.channels) {
    if (!before.containsKey(chan.id)) {
      f.changes.add('NEW channel "${chan.id}" (${chan.name}): '
          '${chan.items.length} items, ${chan.hours} h');
    }
  }

  for (final drop in drops) {
    if (allowDrop) {
      f.warnings.add('$drop (Allowed: the drop was marked as intended.)');
    } else {
      f.failures.add('$drop If that is on purpose, say so: put the words '
          '"drop intended" in the pull request description (or pass '
          '--allow-drop when running this by hand).');
    }
  }
}

/// An existing channel is a broadcast in progress. What is on air is worked
/// out as (time since epoch) modulo (length of the whole loop), so ANY change
/// to the epoch, the order, or a single duration moves every viewer to a
/// different point - mid-programme, the moment the file is published. That is
/// sometimes exactly what is wanted, so it warns rather than fails; the point
/// is that it never happens without somebody having read this line.
void _compareChannel(Chan old, Chan chan, Findings f) {
  final label = 'Channel "${chan.id}" (${chan.name})';
  if (old.name != chan.name) {
    f.changes.add('$label was called "${old.name}"');
  }
  if (old.scheduled != chan.scheduled) {
    f.onAir.add('$label switched between a live stream and a schedule.');
    return;
  }

  if (old.epoch != null && chan.epoch != null && old.epoch != chan.epoch) {
    f.onAir.add('$label: EPOCH CHANGED ${old.epochText} -> ${chan.epochText}.');
  }

  final was = [for (final i in old.items) i.url];
  final now = [for (final i in chan.items) i.url];
  final wasSet = was.toSet();
  final nowSet = now.toSet();
  final added = now.where((u) => !wasSet.contains(u)).length;
  final removed = was.where((u) => !nowSet.contains(u)).length;
  final keptBefore = was.where(nowSet.contains).toList();
  final keptAfter = now.where(wasSet.contains).toList();
  final reordered = !_sameOrder(keptBefore, keptAfter);
  final appendedOnly = added > 0 &&
      removed == 0 &&
      !reordered &&
      _sameOrder(now.sublist(0, was.length), was);

  final oldSeconds = {for (final i in old.items) i.url: i.seconds};
  final retimed = chan.items
      .where((i) => oldSeconds[i.url] != null && oldSeconds[i.url] != i.seconds)
      .toList();

  final what = <String>[
    if (appendedOnly) '$added item(s) ADDED at the end',
    if (added > 0 && !appendedOnly) '$added item(s) INSERTED',
    if (removed > 0) '$removed item(s) REMOVED',
    if (reordered) 'items REORDERED',
    if (retimed.isNotEmpty)
      '${retimed.length} item(s) changed LENGTH '
          '(${retimed.take(3).map((i) => '"${i.title}" '
              '${oldSeconds[i.url]}s -> ${i.seconds}s').join('; ')}'
          '${retimed.length > 3 ? '; ...' : ''})',
  ];
  if (what.isNotEmpty) {
    f.onAir.add('$label: ${what.join(', ')}. '
        'Loop ${old.hours} h -> ${chan.hours} h.');
  }

  final oldCredits = {for (final i in old.items) i.url: i.credit};
  final recredited = chan.items
      .where((i) => oldCredits.containsKey(i.url) &&
          oldCredits[i.url] != i.credit)
      .length;
  if (recredited > 0) {
    f.warnings.add('$label: the credit changed on $recredited item(s). A '
        'credit is a licence condition - check each against the curation '
        'record.');
  }
  final oldTitles = {for (final i in old.items) i.url: i.title};
  final retitled = chan.items
      .where((i) => oldTitles[i.url] != null && oldTitles[i.url] != i.title)
      .length;
  if (retitled > 0) f.changes.add('$label: $retitled title(s) reworded');
}

bool _sameOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void report(
  List<String> paths,
  Catalogue? current,
  Findings f, {
  required bool compared,
}) {
  final out = StringBuffer()
    ..writeln('Catalogue check: ${paths[0]}')
    ..writeln(compared
        ? 'Compared with:   ${paths[1]}'
        : 'Compared with:   nothing (no base file given, so the "version", '
            'drop and on-air checks did not run)')
    ..writeln();

  if (current != null) {
    final items = current.channels.fold(0, (n, c) => n + c.items.length);
    out
      ..writeln('version ${current.version ?? '?'}  |  '
          '${current.channels.length} channels  |  $items scheduled items')
      ..writeln();
    for (final c in current.channels) {
      out.writeln(c.scheduled
          ? '  ${c.id.padRight(14)} ${c.name.padRight(16)} '
              '${c.items.length.toString().padLeft(4)} items  '
              '${c.hours.padLeft(5)} h  from ${c.epochText ?? '?'}'
              '${publicDomainChannelIds.contains(c.id) ? '  (public domain: '
                  'no credits needed)' : ''}'
          : '  ${c.id.padRight(14)} ${c.name.padRight(16)} live stream');
    }
    out.writeln();
  }

  void section(String title, List<String> lines) {
    if (lines.isEmpty) return;
    out.writeln(title);
    for (final line in lines) {
      out.writeln('  - $line');
    }
    out.writeln();
  }

  section('WHAT CHANGED', f.changes);
  if (f.onAir.isNotEmpty) {
    out
      ..writeln('!' * 72)
      ..writeln('!! THIS MOVES WHAT IS ON AIR, FOR EVERYONE, THE MOMENT IT IS '
          'PUBLISHED')
      ..writeln('!' * 72);
    section(
      'Viewers part-way through a programme will be cut to a different one. '
      'Not a failure - but say in the pull request that you meant it.',
      f.onAir,
    );
  }
  section('WARNINGS (do not block, but read them)', f.warnings);
  section('FAILURES', f.failures);

  out.writeln(f.failures.isEmpty
      ? 'RESULT: PASS'
          '${f.onAir.isEmpty && f.warnings.isEmpty ? '' : ' - with '
              '${f.onAir.length + f.warnings.length} warning(s) above'}'
      : 'RESULT: FAIL - ${f.failures.length} problem(s). '
          'Do not publish this file.');
  stdout.write(out);
}
