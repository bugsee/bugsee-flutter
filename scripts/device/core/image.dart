// Pixels for the redaction check: a raw RGB frame (ffmpeg `-f rawvideo -pix_fmt rgb24`, dwebp `-ppm`)
// and the two questions the secure-region verification asks of it: where is the box of this colour, and
// is this rectangle black.
import 'dart:typed_data';

class Rgb {
  const Rgb(this.r, this.g, this.b);
  final int r, g, b;

  @override
  String toString() => 'rgb($r,$g,$b)';
}

class Rect {
  const Rect(this.left, this.top, this.right, this.bottom);
  final int left, top, right, bottom; // right/bottom exclusive

  int get width => right - left;
  int get height => bottom - top;

  @override
  String toString() => '[$left,$top,$right,$bottom]';
}

class RawImage {
  RawImage(this.width, this.height, this.rgb)
    : assert(rgb.length == width * height * 3);

  final int width, height;
  final Uint8List rgb;

  Rgb at(int x, int y) {
    final i = (y * width + x) * 3;
    return Rgb(rgb[i], rgb[i + 1], rgb[i + 2]);
  }

  /// Parses a binary PPM (`P6`), what `dwebp -ppm` writes.
  factory RawImage.fromPpm(Uint8List bytes) {
    var at = 0;
    String token() {
      while (bytes[at] <= 32) {
        at++;
      }
      if (bytes[at] == 0x23) {
        while (bytes[at] != 10) {
          at++;
        }
        return token();
      }
      final start = at;
      while (bytes[at] > 32) {
        at++;
      }
      return String.fromCharCodes(bytes.sublist(start, at));
    }

    if (token() != 'P6') throw const FormatException('not a binary PPM');
    final w = int.parse(token());
    final h = int.parse(token());
    token(); // maxval
    at++; // the single whitespace after it
    return RawImage(w, h, Uint8List.sublistView(bytes, at, at + w * h * 3));
  }

  /// The bounding box of the pixels within [tolerance] (per channel) of [color], or `null`.
  Rect? boundingBoxOf(Rgb color, {int tolerance = 40}) {
    var left = width, top = height, right = -1, bottom = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final p = at(x, y);
        if ((p.r - color.r).abs() <= tolerance &&
            (p.g - color.g).abs() <= tolerance &&
            (p.b - color.b).abs() <= tolerance) {
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
      }
    }
    return right < 0 ? null : Rect(left, top, right + 1, bottom + 1);
  }

  /// The fraction of the pixels inside [r] within [tolerance] of [color].
  double fractionOf(Rect r, Rgb color, {int tolerance = 40}) {
    var hit = 0, total = 0;
    for (var y = r.top.clamp(0, height); y < r.bottom.clamp(0, height); y++) {
      for (var x = r.left.clamp(0, width); x < r.right.clamp(0, width); x++) {
        final p = at(x, y);
        total++;
        if ((p.r - color.r).abs() <= tolerance &&
            (p.g - color.g).abs() <= tolerance &&
            (p.b - color.b).abs() <= tolerance) {
          hit++;
        }
      }
    }
    return total == 0 ? 0 : hit / total;
  }

  /// How many pixels of [r] (clamped to the frame) are within [tolerance] of [color], and how many pixels [r]
  /// covers once clamped.
  ({int hit, int total}) countOf(Rect r, Rgb color, {int tolerance = 40}) {
    var hit = 0, total = 0;
    for (var y = r.top.clamp(0, height); y < r.bottom.clamp(0, height); y++) {
      for (var x = r.left.clamp(0, width); x < r.right.clamp(0, width); x++) {
        final p = at(x, y);
        total++;
        if ((p.r - color.r).abs() <= tolerance &&
            (p.g - color.g).abs() <= tolerance &&
            (p.b - color.b).abs() <= tolerance) {
          hit++;
        }
      }
    }
    return (hit: hit, total: total);
  }

  /// The fraction of the pixels OUTSIDE [hole] that are within [tolerance] (per channel) of the same
  /// pixel of [other] (same size). A frame blacked out entirely agrees with the real one nowhere
  /// outside the box.
  double agreementOutside(RawImage other, Rect hole, {int tolerance = 40}) {
    if (other.width != width || other.height != height) return 0;
    var same = 0, total = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (x >= hole.left &&
            x < hole.right &&
            y >= hole.top &&
            y < hole.bottom) {
          continue;
        }
        total++;
        final a = at(x, y), b = other.at(x, y);
        if ((a.r - b.r).abs() <= tolerance &&
            (a.g - b.g).abs() <= tolerance &&
            (a.b - b.b).abs() <= tolerance) {
          same++;
        }
      }
    }
    return total == 0 ? 0 : same / total;
  }

  /// Binary PPM (`P6`) bytes: any viewer, and ffmpeg, reads them.
  Uint8List toPpm() {
    final head = 'P6\n$width $height\n255\n'.codeUnits;
    return Uint8List.fromList([...head, ...rgb]);
  }

  /// Whether the whole image is (nearly) one colour.
  bool isUniform({int tolerance = 8}) {
    final first = at(0, 0);
    for (var i = 0; i < width * height; i++) {
      if ((rgb[i * 3] - first.r).abs() > tolerance ||
          (rgb[i * 3 + 1] - first.g).abs() > tolerance ||
          (rgb[i * 3 + 2] - first.b).abs() > tolerance) {
        return false;
      }
    }
    return true;
  }
}

/// How two boxes of the same region compare: the redaction must cover the region and not much more.
extension RectGrow on Rect {
  Rect grow(int by) => Rect(left - by, top - by, right + by, bottom + by);
}

class Coverage {
  const Coverage(this.region, this.redaction);
  final Rect region;
  final Rect redaction;

  /// The part of [region] the redaction does not reach, per side (positive = uncovered pixels).
  Map<String, int> get uncovered => {
    'left': redaction.left - region.left,
    'top': redaction.top - region.top,
    'right': region.right - redaction.right,
    'bottom': region.bottom - redaction.bottom,
  };

  /// Redaction over region, by area: 1.0 is exact, below it the region is not fully covered.
  double get areaRatio =>
      (redaction.width * redaction.height) / (region.width * region.height);
}
