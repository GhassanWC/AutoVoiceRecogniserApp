// Builds the launcher-icon layers from ONE source image.
//
//   assets/branding/app_icon_source.png   ← the only file to replace
//     ├─ assets/icon/app_icon.png            full-bleed master (iOS + Android legacy)
//     ├─ assets/icon/app_icon_background.png Android adaptive background layer
//     └─ assets/icon/app_icon_foreground.png Android adaptive foreground layer
//
// Run:  dart run tool/generate_app_icons.dart
//
// That rebuilds the layers above, then runs flutter_launcher_icons to write
// every iOS/Android size, then repairs one unrelated Xcode build setting that
// flutter_launcher_icons 0.14 clobbers (see _repairXcodeProject).
//
// The branding is NOT redesigned here. The source artwork is a rounded icon
// tile sitting on a white page, which platforms cannot use directly:
//   * iOS wants a square, full-bleed, alpha-free image and applies its own
//     corner mask — shipping the source as-is would show a small rounded tile
//     inside a white square.
//   * Android adaptive icons need the backdrop and the mark as SEPARATE layers
//     so the launcher can mask/parallax them.
// So the tile is trimmed out of the white page, its corner slivers are filled
// with a gradient sampled from the artwork's own pixels, and the white mark is
// separated from the blue backdrop by saturation. Every colour comes from the
// source image; nothing is invented.

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

const String kSource = 'assets/branding/app_icon_source.png';
const String kOutDir = 'assets/icon';

/// Master icon edge in px (1024 is what the App Store and Play Store want).
const int kMasterSize = 1024;

/// Mark size relative to the finished square icon (iOS + Android legacy),
/// matching the proportion the mark has in the source artwork (~67% of the
/// tile) so its padding is preserved.
const double kMasterMarkFraction = 0.68;

/// Android adaptive icons guarantee only the middle 72/108 (66.7%) of the
/// canvas is visible; anything outside can be clipped by a launcher mask.
/// flutter_launcher_icons ALSO wraps the foreground drawable in a 16%-per-edge
/// inset (leaving 68% of the layer), so the mark is scaled up here to land at
/// [kTargetMarkFraction] of the finished icon — inside the safe zone, and
/// matching the weight the mark has in the source artwork (~67% of the tile).
const double kAdaptiveForegroundInset = 0.68; // mirrors the generated XML
const double kTargetMarkFraction = 0.64;
const double kForegroundMarkFraction =
    kTargetMarkFraction / kAdaptiveForegroundInset;

/// Saturation ramp separating the white mark from the saturated blue backdrop.
/// The mark's lightest shading sits near 0.22 and the backdrop never drops
/// below ~0.85, so a 0.35→0.60 ramp lands safely in the empty middle.
const double kMarkSatFull = 0.35;
const double kMarkSatNone = 0.60;

Future<void> main(List<String> args) async {
  final sourceFile = File(kSource);
  if (!sourceFile.existsSync()) {
    stderr.writeln('Source image not found: $kSource');
    exitCode = 1;
    return;
  }
  final source = decodePng(sourceFile.readAsBytesSync());
  if (source == null) {
    stderr.writeln('Could not decode $kSource');
    exitCode = 1;
    return;
  }
  stdout.writeln('source ${source.width}x${source.height}');

  final tile = _cropTile(source);
  stdout.writeln('icon tile ${tile.width}x${tile.height} (white page trimmed)');

  final gradient = _sampleGradient(tile);
  final mark = _extractMark(tile);

  // ── Full-bleed master (iOS + Android legacy): the sampled backdrop with
  // the untouched mark centred on it. Building it this way is what removes
  // the artwork's outer glossy bevel — it is cropped away with the tile's
  // rounded edge rather than scaled into frame — and it leaves ONE uniform
  // backdrop, so there is no seam where real artwork would meet fill.
  final master = Image(width: kMasterSize, height: kMasterSize, numChannels: 4);
  _paintGradient(master, gradient);
  _placeCentered(master, mark, kMasterMarkFraction);
  _write('app_icon.png', master, alpha: false);

  // ── Android adaptive background: the same backdrop, full bleed.
  final background = Image(width: kMasterSize, height: kMasterSize, numChannels: 4);
  _paintGradient(background, gradient);
  _write('app_icon_background.png', background, alpha: false);

  // ── Android adaptive foreground: the same mark, sized for the safe zone.
  final foreground = Image(width: kMasterSize, height: kMasterSize, numChannels: 4);
  _placeCentered(foreground, mark, kForegroundMarkFraction);
  _write('app_icon_foreground.png', foreground, alpha: true);

  if (args.contains('--layers-only')) {
    stdout.writeln('\nLayers only. Next: dart run flutter_launcher_icons');
    return;
  }
  await _runLauncherIcons();
  _repairXcodeProject();
}

/// Writes every platform icon size from the layers above.
Future<void> _runLauncherIcons() async {
  stdout.writeln('\n→ dart run flutter_launcher_icons');
  final result = await Process.run(
    'dart',
    ['run', 'flutter_launcher_icons'],
    runInShell: true,
  );
  stdout.write(result.stdout);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    stderr.writeln('flutter_launcher_icons failed (exit ${result.exitCode}). '
        'Is it in dev_dependencies?');
    exitCode = result.exitCode;
  }
}

/// flutter_launcher_icons 0.14 overwrites the value of the FIRST build setting
/// whose name starts with `ASSETCATALOG_COMPILER_`, which in this project is
/// the boolean ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS —
/// leaving it as `AppIcon` instead of `YES`. The real app-icon setting
/// (ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon) is already correct in every
/// build configuration, so just put the boolean back.
void _repairXcodeProject() {
  final project = File('ios/Runner.xcodeproj/project.pbxproj');
  if (!project.existsSync()) return;
  const setting = 'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS';
  final original = project.readAsStringSync();
  final repaired = original.replaceAll('$setting = AppIcon;', '$setting = YES;');
  if (repaired != original) {
    project.writeAsStringSync(repaired);
    stdout.writeln('repaired $setting in project.pbxproj');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Trim the white page around the icon tile
// ─────────────────────────────────────────────────────────────────────────────

/// Flood-fills the near-white page inward from the four corners, then crops to
/// what is left. Flood fill (rather than a global white threshold) is what
/// keeps the white LOGO MARK — which is the same colour as the page — intact.
Image _cropTile(Image source) {
  final w = source.width;
  final h = source.height;
  final isPage = List<bool>.filled(w * h, false);
  final queue = <int>[];

  bool nearWhite(int x, int y) {
    final p = source.getPixel(x, y);
    return p.r > 233 && p.g > 233 && p.b > 233;
  }

  void seed(int x, int y) {
    final i = y * w + x;
    if (!isPage[i] && nearWhite(x, y)) {
      isPage[i] = true;
      queue.add(i);
    }
  }

  for (var x = 0; x < w; x++) {
    seed(x, 0);
    seed(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    seed(0, y);
    seed(w - 1, y);
  }
  while (queue.isNotEmpty) {
    final i = queue.removeLast();
    final x = i % w;
    final y = i ~/ w;
    if (x > 0) seed(x - 1, y);
    if (x < w - 1) seed(x + 1, y);
    if (y > 0) seed(x, y - 1);
    if (y < h - 1) seed(x, y + 1);
  }

  var minX = w, minY = h, maxX = -1, maxY = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (isPage[y * w + x]) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < minX || maxY < minY) {
    throw StateError('Could not find the icon tile inside $kSource');
  }

  // Square the crop around the tile's centre so nothing is stretched.
  final side = math.max(maxX - minX + 1, maxY - minY + 1);
  final cx = (minX + maxX) ~/ 2;
  final cy = (minY + maxY) ~/ 2;
  final left = (cx - side ~/ 2).clamp(0, w - 1);
  final top = (cy - side ~/ 2).clamp(0, h - 1);
  final clipped = math.min(side, math.min(w - left, h - top));

  final tile = Image(width: clipped, height: clipped, numChannels: 4);
  for (var y = 0; y < clipped; y++) {
    for (var x = 0; x < clipped; x++) {
      final sx = left + x;
      final sy = top + y;
      // Page pixels become transparent so the gradient shows through the
      // tile's rounded corners.
      if (isPage[sy * w + sx]) continue;
      final p = source.getPixel(sx, sy);
      tile.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), 255);
    }
  }
  return tile;
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-bleed master
// ─────────────────────────────────────────────────────────────────────────────

/// Scales [mark] to [fraction] of [target]'s width and centres it.
void _placeCentered(Image target, Image mark, double fraction) {
  final size = (target.width * fraction).round();
  final scaled = copyResize(mark,
      width: size, height: size, interpolation: Interpolation.cubic);
  compositeImage(target, scaled,
      dstX: (target.width - size) ~/ 2, dstY: (target.height - size) ~/ 2);
}

// ─────────────────────────────────────────────────────────────────────────────
// Backdrop gradient, sampled from the artwork itself
// ─────────────────────────────────────────────────────────────────────────────

class _Gradient {
  const _Gradient(this.topLeft, this.topRight, this.bottomLeft, this.bottomRight);
  final List<int> topLeft;
  final List<int> topRight;
  final List<int> bottomLeft;
  final List<int> bottomRight;
}

/// Averages backdrop pixels near each corner of the tile (inside the rounded
/// shape, well away from the centred mark) to get the four gradient stops.
_Gradient _sampleGradient(Image tile) {
  final size = tile.width;
  final inset = (size * 0.17).round();
  final radius = (size * 0.045).round();

  List<int> sample(int cx, int cy) {
    var r = 0, g = 0, b = 0, n = 0;
    for (var y = cy - radius; y <= cy + radius; y++) {
      for (var x = cx - radius; x <= cx + radius; x++) {
        if (x < 0 || y < 0 || x >= size || y >= size) continue;
        final p = tile.getPixel(x, y);
        if (p.a < 255) continue;
        // Skip anything unsaturated: never average the mark or a rim
        // highlight into a backdrop stop.
        if (_saturation(p.r.toInt(), p.g.toInt(), p.b.toInt()) < kMarkSatNone) {
          continue;
        }
        r += p.r.toInt();
        g += p.g.toInt();
        b += p.b.toInt();
        n++;
      }
    }
    if (n == 0) return [21, 96, 255];
    return [r ~/ n, g ~/ n, b ~/ n];
  }

  final gradient = _Gradient(
    sample(inset, inset),
    sample(size - 1 - inset, inset),
    sample(inset, size - 1 - inset),
    sample(size - 1 - inset, size - 1 - inset),
  );
  stdout.writeln('gradient stops  TL=${_hex(gradient.topLeft)} '
      'TR=${_hex(gradient.topRight)} BL=${_hex(gradient.bottomLeft)} '
      'BR=${_hex(gradient.bottomRight)}');
  return gradient;
}

/// Bilinear fill between the four sampled stops.
void _paintGradient(Image target, _Gradient gradient) {
  final w = target.width;
  final h = target.height;
  for (var y = 0; y < h; y++) {
    final fy = h == 1 ? 0.0 : y / (h - 1);
    for (var x = 0; x < w; x++) {
      final fx = w == 1 ? 0.0 : x / (w - 1);
      int channel(int i) {
        final top = gradient.topLeft[i] + (gradient.topRight[i] - gradient.topLeft[i]) * fx;
        final bottom =
            gradient.bottomLeft[i] + (gradient.bottomRight[i] - gradient.bottomLeft[i]) * fx;
        return (top + (bottom - top) * fy).round().clamp(0, 255);
      }

      target.setPixelRgba(x, y, channel(0), channel(1), channel(2), 255);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The white mark, isolated from the backdrop
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the logo mark alone — original pixels, soft alpha, cropped square
/// and tight to its bounds. Used unchanged for both the square master icon and
/// the Android adaptive foreground.
Image _extractMark(Image tile) {
  final size = tile.width;
  // Ignore a border band: the tile's glossy bevel/rim is also unsaturated, and
  // excluding it here is what keeps it out of every generated icon.
  final border = (size * 0.07).round();

  // Soft alpha across the saturation ramp keeps anti-aliased edges smooth.
  final alpha = List<int>.filled(size * size, 0);
  for (var y = border; y < size - border; y++) {
    for (var x = border; x < size - border; x++) {
      final p = tile.getPixel(x, y);
      if (p.a < 255) continue;
      final sat = _saturation(p.r.toInt(), p.g.toInt(), p.b.toInt());
      final t = ((kMarkSatNone - sat) / (kMarkSatNone - kMarkSatFull)).clamp(0.0, 1.0);
      alpha[y * size + x] = (t * 255).round();
    }
  }

  // The rim highlight and other glints also read as "unsaturated", so keep
  // only large connected blobs — that is the mark (its two bubbles) and
  // nothing else. Without this, stray specks both inflate the crop (shrinking
  // the mark) and render as dirt in the launcher.
  final kept = _largeBlobs(alpha, size, minArea: (size * size * 0.01).round());

  final mark = Image(width: size, height: size, numChannels: 4);
  var minX = size, minY = size, maxX = -1, maxY = -1;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final i = y * size + x;
      if (!kept[i] || alpha[i] == 0) continue;
      final p = tile.getPixel(x, y);
      mark.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), alpha[i]);
      if (alpha[i] > 128) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < minX || maxY < minY) {
    throw StateError('Could not isolate the logo mark in $kSource');
  }

  // Square crop centred on the mark so it is never stretched.
  final side = math.max(maxX - minX + 1, maxY - minY + 1);
  final cx = (minX + maxX) ~/ 2;
  final cy = (minY + maxY) ~/ 2;
  stdout.writeln('mark ${side}x$side at ($cx,$cy) '
      '= ${(side / size * 100).round()}% of the tile');
  return copyCrop(
    mark,
    x: cx - side ~/ 2,
    y: cy - side ~/ 2,
    width: side,
    height: side,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Flags pixels belonging to connected blobs of at least [minArea] solid
/// pixels, then grows the result slightly so each blob keeps its soft
/// anti-aliased fringe.
List<bool> _largeBlobs(List<int> alpha, int size, {required int minArea}) {
  const solidCutoff = 90; // ≈ alpha ramp t > 0.35
  final visited = List<bool>.filled(size * size, false);
  final kept = List<bool>.filled(size * size, false);
  var blobs = 0;

  for (var start = 0; start < alpha.length; start++) {
    if (visited[start] || alpha[start] < solidCutoff) continue;
    final blob = <int>[];
    final stack = <int>[start];
    visited[start] = true;
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      blob.add(i);
      final x = i % size;
      final y = i ~/ size;
      void push(int nx, int ny) {
        if (nx < 0 || ny < 0 || nx >= size || ny >= size) return;
        final n = ny * size + nx;
        if (visited[n] || alpha[n] < solidCutoff) return;
        visited[n] = true;
        stack.add(n);
      }

      push(x - 1, y);
      push(x + 1, y);
      push(x, y - 1);
      push(x, y + 1);
    }
    if (blob.length < minArea) continue;
    blobs++;
    for (final i in blob) {
      kept[i] = true;
    }
  }
  stdout.writeln('kept $blobs mark blob(s)');

  // Dilate by a few pixels so the soft edge of each blob survives.
  const grow = 3;
  final grown = List<bool>.filled(size * size, false);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (!kept[y * size + x]) continue;
      for (var dy = -grow; dy <= grow; dy++) {
        for (var dx = -grow; dx <= grow; dx++) {
          final nx = x + dx;
          final ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= size || ny >= size) continue;
          grown[ny * size + nx] = true;
        }
      }
    }
  }
  return grown;
}

double _saturation(int r, int g, int b) {
  final max = math.max(r, math.max(g, b));
  if (max == 0) return 0;
  final min = math.min(r, math.min(g, b));
  return (max - min) / max;
}

String _hex(List<int> rgb) => '#'
    '${rgb[0].toRadixString(16).padLeft(2, '0')}'
    '${rgb[1].toRadixString(16).padLeft(2, '0')}'
    '${rgb[2].toRadixString(16).padLeft(2, '0')}';

void _write(String name, Image image, {required bool alpha}) {
  final out = alpha ? image : image.convert(numChannels: 3);
  File('$kOutDir/$name').writeAsBytesSync(encodePng(out));
  stdout.writeln('wrote $kOutDir/$name ${out.width}x$out.height'
      .replaceAll('x$out.height', 'x${out.height}'));
}
