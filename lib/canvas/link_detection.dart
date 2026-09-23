import 'dart:io';

import 'package:flutter/foundation.dart';

/// What kind of thing a [DetectedUrl] points at, so the caller knows
/// how to open it: a web address goes to url_launcher, a local file
/// goes to open_file. They're not interchangeable - see the doc
/// comment on [findUrls] for why a bare local file:// path can't just
/// go through url_launcher too.
enum LinkKind { web, localFile }

/// One link found inside a block of text: raw start/end character
/// offsets into that text (so callers can compare against a tap or
/// cursor position, or slice out the substring), which [kind] of link
/// it is, and [target] - the address/path to actually open (already
/// defaulted to "https://" for a bare "www.example.com" web link;
/// exactly as typed, aside from trailing-punctuation trimming, for a
/// local file).
@immutable
class DetectedUrl {
  const DetectedUrl({required this.start, required this.end, required this.kind, required this.target});

  final int start;
  final int end;
  final LinkKind kind;
  final String target;

  bool contains(int offset) => offset >= start && offset < end;
}

/// Web links: "http://…"/"https://…" and bare "www.…" addresses.
final RegExp _webPattern = RegExp(
  r'(https?://\S+)|(\bwww\.\S+\.\S+)',
  caseSensitive: false,
);

/// Local file references: a "file://" URI, a Windows drive-letter path
/// (C:\... or C:/...), a Windows UNC path (\\server\share\...), or a
/// POSIX/Android absolute path (/storage/...). The last three only
/// count when they end in a recognizable file extension - that's what
/// keeps this from matching ordinary prose that happens to contain a
/// colon or a slash (a time like "3:45", a fraction like "3/4"); a
/// stretch of non-whitespace text ending in ".something" is a much
/// stronger signal that it's actually a file path someone typed or
/// pasted.
final RegExp _localFilePattern = RegExp(
  r'(file://\S+)'
  r'|([A-Za-z]:[\\/]\S*\.[A-Za-z0-9]{1,6})'
  r'|(\\\\\S+\.[A-Za-z0-9]{1,6})'
  r'|(/\S+/\S*\.[A-Za-z0-9]{1,6})',
  caseSensitive: false,
);

/// Trailing characters trimmed off a raw match - punctuation someone
/// would naturally type right after a link in a sentence ("...see
/// https://example.com." or "(https://example.com)"), never actually
/// part of the address/path itself.
const String _trailingPunctuation = '.,;:!?)\'"”’';

/// Finds every web link or local file reference in [text], in reading
/// order, trimming ordinary trailing sentence punctuation off each
/// match so "visit https://x.com." only links "https://x.com".
///
/// A local file match is meant to be opened with open_file rather than
/// url_launcher: Android throws a FileUriExposedException if an app
/// hands a raw file:// URI straight to another app via an intent (a
/// deliberate security restriction, not a bug) - open_file's own
/// bundled Android setup routes it through a FileProvider/content://
/// URI instead, which is exempt. Windows has no such restriction, but
/// open_file covers it too, so the same call works on both - see
/// InfiniteCanvas._openDetectedLink.
List<DetectedUrl> findUrls(String text) {
  final results = <DetectedUrl>[];

  void collect(RegExp pattern, LinkKind kind) {
    for (final match in pattern.allMatches(text)) {
      var end = match.end;
      var raw = match.group(0)!;
      while (raw.isNotEmpty && _trailingPunctuation.contains(raw[raw.length - 1])) {
        raw = raw.substring(0, raw.length - 1);
        end--;
      }
      if (raw.isEmpty) continue;
      if (kind == LinkKind.web) {
        final hasScheme = RegExp(r'^https?://', caseSensitive: false).hasMatch(raw);
        final uri = Uri.tryParse(hasScheme ? raw : 'https://$raw');
        if (uri == null || uri.host.isEmpty) continue;
        results.add(DetectedUrl(start: match.start, end: end, kind: kind, target: uri.toString()));
      } else {
        results.add(DetectedUrl(start: match.start, end: end, kind: kind, target: raw));
      }
    }
  }

  collect(_webPattern, LinkKind.web);
  collect(_localFilePattern, LinkKind.localFile);
  results.sort((a, b) => a.start.compareTo(b.start));

  // The two patterns can't actually start at the same position (one
  // needs "http"/"www.", the other "file://"/a drive letter/"\\"/"/"),
  // but guard against any future overlap anyway rather than ever
  // handing the caller two overlapping links for the same text.
  final deduped = <DetectedUrl>[];
  var lastEnd = -1;
  for (final url in results) {
    if (url.start < lastEnd) continue;
    deduped.add(url);
    lastEnd = url.end;
  }
  return deduped;
}

/// Converts a detected [LinkKind.localFile] target (findUrls'
/// [DetectedUrl.target], or the same raw text stored as a key in
/// [NotePage.embeddedLinks]) into an actual filesystem path this
/// device can hand to [File]/OpenFile.open: strips a leading
/// "file://" URI scheme (decoding %20 and the like via
/// Uri.toFilePath), or returns the text unchanged if it's already a
/// plain path - a Windows drive/UNC path or a POSIX/Android absolute
/// path never has "file://" on it in the first place. Shared by
/// InfiniteCanvas._openLocalFile and PageScreen's link-embedding logic
/// so both agree on what a given link's raw text actually points at.
String resolveLocalFilePath(String rawTarget) {
  return rawTarget.toLowerCase().startsWith('file://')
      ? Uri.parse(rawTarget).toFilePath(windows: Platform.isWindows)
      : rawTarget;
}

/// The [DetectedUrl] in [text] (via [findUrls]) whose range contains
/// character offset [position], or null if [position] isn't inside any
/// detected link.
DetectedUrl? urlAt(String text, int position) {
  for (final url in findUrls(text)) {
    if (url.contains(position)) return url;
  }
  return null;
}
