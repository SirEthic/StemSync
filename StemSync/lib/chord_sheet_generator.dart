import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Generates a rhythm-slash chord lead sheet as a valid PDF 1.4 file.
/// Pure Dart — no external package required.
class ChordSheetGenerator {
  // A4 page in PDF points (1 pt = 1/72 inch)
  static const double _pw = 595.28;
  static const double _ph = 841.89;
  static const double _margin = 45.0;
  static const int _measPerRow = 4;
  static const double _rowH = 72.0; // vertical space per row
  static const double _staffLineGap = 5.5; // gap between each of 5 staff lines
  static const double _staffH = _staffLineGap * 4;

  // ── Public entry-point ────────────────────────────────────────────────────
  static Future<File?> generateAndSaveChordSheet(
    String title,
    List<dynamic> chords,
    double tempoBpm,
  ) async {
    if (chords.isEmpty) return null;

    // 1. Quantise chords into a measure/beat grid
    final measures = _buildMeasures(chords, tempoBpm);
    if (measures.isEmpty) return null;

    // 2. Build one content-stream string per page
    final pages = _buildPageStreams(title, tempoBpm, measures);

    // 3. Serialise to PDF bytes
    final bytes = _serialisePdf(pages);

    // 4. Write to temp file — named after the song
    final dir = await getTemporaryDirectory();
    final safeName = title
        .replaceAll(RegExp(r'[^\w\s\-]'), '')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    final clipped = safeName.length > 40 ? safeName.substring(0, 40) : safeName;
    final file = File('${dir.path}/${clipped}_chord_sheet.pdf');
    await file.writeAsBytes(bytes);
    return file;
  }

  // ── Step 1 – Quantise ─────────────────────────────────────────────────────
  static List<List<String>> _buildMeasures(
      List<dynamic> chords, double tempoBpm) {
    final double spb = 60.0 / tempoBpm; // seconds per beat
    final double spm = spb * 4; // seconds per measure

    double lastTime = 0;
    for (var c in chords) {
      final t = c['time'];
      if (t != null) {
        final d = (t as num).toDouble();
        if (d > lastTime) lastTime = d;
      }
    }

    int totalMeasures = (lastTime / spm).ceil() + 1;
    if (totalMeasures < 1) totalMeasures = 1;

    final measures =
        List.generate(totalMeasures, (_) => List.filled(4, '', growable: false));

    for (var c in chords) {
      final rawTime = c['time'];
      final rawChord = c['chord'];
      if (rawTime == null || rawChord == null) continue;

      final String chord = rawChord.toString().trim();
      if (chord.isEmpty || chord == 'N' || chord == 'N/C') continue;

      final double start = (rawTime as num).toDouble();
      final int mi = (start / spm).floor();
      final double tim = start - mi * spm;
      final int bi = (tim / spb).floor().clamp(0, 3);

      if (mi >= 0 && mi < totalMeasures && measures[mi][bi].isEmpty) {
        measures[mi][bi] = chord;
      }
    }

    return measures;
  }

  // ── Step 2 – Build page content streams ───────────────────────────────────
  static List<String> _buildPageStreams(
      String title, double tempoBpm, List<List<String>> measures) {
    final double usableW = _pw - _margin * 2;
    final double measW = usableW / _measPerRow;
    final double beatW = measW / 4;
    final int totalRows = (measures.length / _measPerRow).ceil();

    // First page has a header; subsequent pages start right away
    const double headerH = 52.0;
    final int rowsFirstPage =
        ((_ph - _margin * 2 - headerH) / _rowH).floor().clamp(1, 9999);
    final int rowsOtherPage =
        ((_ph - _margin * 2) / _rowH).floor().clamp(1, 9999);

    final List<String> pageStreams = [];
    int row = 0;

    while (row < totalRows) {
      final bool isFirst = pageStreams.isEmpty;
      final int rowsThisPage = isFirst ? rowsFirstPage : rowsOtherPage;
      final int lastRow = (row + rowsThisPage).clamp(0, totalRows);

      final sb = StringBuffer();

      // PDF Y is bottom-up; helper flips our top-down coords
      double y(double topDown) => _ph - topDown;

      void line(double x1, double td1, double x2, double td2, double w) {
        sb.write('$w w '
            '${f(x1)} ${f(y(td1))} m '
            '${f(x2)} ${f(y(td2))} l S\n');
      }

      // Text in a single call (BT…ET block)
      void txt(String t, double x, double tdY, double size) {
        final esc = t
            .replaceAll('\\', '\\\\')
            .replaceAll('(', '\\(')
            .replaceAll(')', '\\)');
        sb.write(
            'BT /F1 ${f(size)} Tf ${f(x)} ${f(y(tdY))} Td ($esc) Tj ET\n');
      }

      // ── Header ────────────────────────────────────────────────────────
      if (isFirst) {
        // Title centred on its own line
        final double titleSize = 18.0;
        final double titleW = title.length * titleSize * 0.55;
        txt(title, (_pw - titleW) / 2, _margin + 18, titleSize);
        // Tempo on the line below, left-aligned
        txt('q = ${tempoBpm.round()} BPM', _margin, _margin + 38, 10);
      }

      // ── Rows ──────────────────────────────────────────────────────────
      final double topOfRows = isFirst ? _margin + headerH : _margin;

      for (int r = row; r < lastRow; r++) {
        final double rowTop = topOfRows + (r - row) * _rowH;
        final double staffTop = rowTop + 24; // 24 pt above staff for chord names

        // 5 staff lines
        for (int li = 0; li < 5; li++) {
          final double ly = staffTop + li * _staffLineGap;
          line(_margin, ly, _pw - _margin, ly, 0.5);
        }

        // Outer bar lines
        line(_margin, staffTop, _margin, staffTop + _staffH, 1.0);
        line(_pw - _margin, staffTop, _pw - _margin, staffTop + _staffH, 1.0);

        // Measure number (small, left of row)
        final int firstMeas = r * _measPerRow;
        txt('${firstMeas + 1}', _margin - 18, staffTop + 5, 7);

        // Measures
        for (int m = 0; m < _measPerRow; m++) {
          final int mi = r * _measPerRow + m;
          if (mi >= measures.length) break;

          final double mLeft = _margin + m * measW;

          // Inner bar line
          if (m > 0) {
            line(mLeft, staffTop, mLeft, staffTop + _staffH, 0.8);
          }

          // Beats
          for (int b = 0; b < 4; b++) {
            final double cx = mLeft + (b + 0.5) * beatW;
            // Rhythm slash — diagonal from bottom-left to top-right
            line(cx - 5, staffTop + _staffH - 3, cx + 5, staffTop + 3, 1.8);

            final String chord = measures[mi][b];
            if (chord.isNotEmpty) {
              // Centre chord name above the beat's slash, 14pt above staff top
              final double approxW = chord.length * 5.5;
              txt(chord, cx - approxW / 2, staffTop - 14, 9);
            }
          }
        }
      }

      pageStreams.add(sb.toString());
      row = lastRow;
    }

    return pageStreams;
  }

  // ── Step 3 – Serialise to raw PDF bytes ───────────────────────────────────
  static Uint8List _serialisePdf(List<String> pageStreams) {
    final int numPages = pageStreams.length;

    // Object layout:
    //  1 = Catalog
    //  2 = Pages
    //  3 = Font
    //  4..4+numPages-1 = Page objects
    //  4+numPages..4+2*numPages-1 = Content streams
    final int firstPageObj = 4;
    final int firstContentObj = 4 + numPages;
    // Highest object ID = 3 (font) + numPages (pages) + numPages (streams)
    final int totalObjs = 3 + 2 * numPages;

    final List<int> out = [];
    final List<int> offsets = List.filled(totalObjs + 1, 0); // 1-indexed

    void w(String s) => out.addAll(s.codeUnits);
    void wl(String s) => w('$s\n');

    void beginObj(int id) {
      offsets[id] = out.length;
      wl('$id 0 obj');
    }

    void endObj() => wl('endobj\n');

    // Header
    wl('%PDF-1.4');

    // Object 1 – Catalog
    beginObj(1);
    wl('<< /Type /Catalog /Pages 2 0 R >>');
    endObj();

    // Object 2 – Pages
    beginObj(2);
    final kids =
        List.generate(numPages, (i) => '${firstPageObj + i} 0 R').join(' ');
    wl('<< /Type /Pages /Kids [$kids] /Count $numPages >>');
    endObj();

    // Object 3 – Font
    beginObj(3);
    wl('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold '
        '/Encoding /WinAnsiEncoding >>');
    endObj();

    // Page objects
    for (int i = 0; i < numPages; i++) {
      final int pageId = firstPageObj + i;
      final int contentId = firstContentObj + i;
      beginObj(pageId);
      wl('<< /Type /Page /Parent 2 0 R');
      wl('   /MediaBox [0 0 ${f(_pw)} ${f(_ph)}]');
      wl('   /Resources << /Font << /F1 3 0 R >> >>');
      wl('   /Contents $contentId 0 R >>');
      endObj();
    }

    // Content stream objects
    for (int i = 0; i < numPages; i++) {
      final int contentId = firstContentObj + i;
      final String stream = pageStreams[i];
      beginObj(contentId);
      wl('<< /Length ${stream.length} >>');
      wl('stream');
      w(stream);
      wl('endstream');
      endObj();
    }

    // xref
    final int xrefOffset = out.length;
    wl('xref');
    wl('0 ${totalObjs + 1}');
    wl('0000000000 65535 f ');
    for (int id = 1; id <= totalObjs; id++) {
      wl(offsets[id].toString().padLeft(10, '0') + ' 00000 n ');
    }

    // Trailer
    wl('trailer');
    wl('<< /Size ${totalObjs + 1} /Root 1 0 R >>');
    wl('startxref');
    wl('$xrefOffset');
    w('%%EOF');

    return Uint8List.fromList(out);
  }

  static String f(double v) => v.toStringAsFixed(2);
}