import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Generates a rhythm-slash chord lead sheet as a raw PDF file.
/// No third-party pdf package needed — we write valid PDF 1.4 bytes directly.
class ChordSheetGenerator {
  // PDF page size: A4 in points (1 pt = 1/72 inch)
  static const double _pageW = 595.28;
  static const double _pageH = 841.89;
  static const double _margin = 40;
  static const int _measuresPerRow = 4;
  static const double _staffLineSpacing = 6.0; // space between the 5 staff lines
  static const double _staffHeight = _staffLineSpacing * 4; // total height of staff
  static const double _rowHeight = 70.0; // vertical space per row of staves

  static Future<File?> generateAndSaveChordSheet(
    String title,
    List<dynamic> chords,
    double tempoBpm,
  ) async {
    if (chords.isEmpty) return null;

    // ── 1. Quantise chords into measures ─────────────────────────────────────
    final double secondsPerBeat = 60.0 / tempoBpm;
    final double secondsPerMeasure = secondsPerBeat * 4;

    double lastTime = 0;
    for (var c in chords) {
      final t = c['time'];
      if (t != null) {
        final d = (t as num).toDouble();
        if (d > lastTime) lastTime = d;
      }
    }

    int totalMeasures = (lastTime / secondsPerMeasure).ceil() + 1;
    if (totalMeasures < 1) totalMeasures = 1;

    // Each measure holds 4 beat-slots
    final List<List<String>> measures =
        List.generate(totalMeasures, (_) => ['', '', '', '']);

    for (var c in chords) {
      final rawTime = c['time'];
      final rawChord = c['chord'];
      if (rawTime == null || rawChord == null) continue;

      final double start = (rawTime as num).toDouble();
      final String chordName = rawChord.toString().trim();
      if (chordName.isEmpty || chordName == 'N' || chordName == 'N/C') continue;

      final int measureIndex = (start / secondsPerMeasure).floor();
      final double timeInMeasure = start - measureIndex * secondsPerMeasure;
      final int beatIndex =
          (timeInMeasure / secondsPerBeat).round().clamp(0, 3);

      if (measureIndex >= 0 && measureIndex < measures.length) {
        // Only write chord if the slot is empty (first chord wins per beat)
        if (measures[measureIndex][beatIndex].isEmpty) {
          measures[measureIndex][beatIndex] = chordName;
        }
      }
    }

    // ── 2. Build PDF pages ────────────────────────────────────────────────────
    final double usableW = _pageW - _margin * 2;
    final double measureW = usableW / _measuresPerRow;
    final double beatW = measureW / 4;

    // How many rows fit on one page?
    // Reserve top of first page for title + tempo header (~60 pt)
    const double headerHeight = 60.0;
    final int rowsPerPage =
        ((_pageH - _margin * 2 - headerHeight) / _rowHeight).floor();

    final int totalRows = (totalMeasures / _measuresPerRow).ceil();
    final int totalPages = (totalRows / rowsPerPage).ceil().clamp(1, 999);

    // ── 3. Emit raw PDF ───────────────────────────────────────────────────────
    final buf = StringBuffer();

    // We collect object byte-offsets for the xref table
    final List<int> offsets = [];
    final rawBytes = <int>[];

    void emit(String s) {
      rawBytes.addAll(s.codeUnits);
    }

    void emitLn(String s) => emit('$s\n');

    // Helper: record offset and start an object
    void startObj(int n) {
      offsets.add(rawBytes.length);
      emitLn('$n 0 obj');
    }

    void endObj() => emitLn('endobj\n');

    // ── Header ─────────────────────────────────────────────────────────────
    emit('%PDF-1.4\n');

    // Object 1 – Catalog
    startObj(1);
    emitLn('<< /Type /Catalog /Pages 2 0 R >>');
    endObj();

    // Object 2 – Pages (kids filled after we know page object IDs)
    // We'll patch this later; for now, reserve the slot
    final int pagesObjOffset = rawBytes.length;
    offsets.add(rawBytes.length); // will be overwritten
    // placeholder – we overwrite offsets[1] after writing all pages
    // Actually, build the pages content string
    // Strategy: write pages first as a forward-ref-free approach.
    // PDF allows forward references so this is fine.

    // Object 2 – Pages dictionary placeholder
    startObj(2);
    final pageKids =
        List.generate(totalPages, (i) => '${3 + i} 0 R').join(' ');
    emitLn('<< /Type /Pages /Kids [$pageKids] /Count $totalPages >>');
    endObj();

    // Helvetica font (built-in, no embedding needed)
    // Object 3+totalPages = Font
    final int fontObjId = 3 + totalPages;
    // Write page content objects first (ids 3..3+totalPages-1)
    final List<int> pageContentIds = [];
    final int contentStartId = 3 + totalPages + 1;

    // ── Write Page objects (3..3+totalPages-1) ───────────────────────────
    for (int pg = 0; pg < totalPages; pg++) {
      startObj(3 + pg);
      emitLn(
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${_pageW.toStringAsFixed(2)} ${_pageH.toStringAsFixed(2)}]');
      emitLn(
          '   /Resources << /Font << /F1 $fontObjId 0 R >> >> /Contents ${contentStartId + pg} 0 R >>');
      endObj();
      pageContentIds.add(contentStartId + pg);
    }

    // ── Font object ──────────────────────────────────────────────────────
    startObj(fontObjId);
    emitLn(
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>');
    endObj();

    // ── Content streams (one per page) ───────────────────────────────────
    for (int pg = 0; pg < totalPages; pg++) {
      final sb = StringBuffer();

      // PDF graphics: origin is bottom-left, Y increases upward
      // We work in top-down coordinates and flip at emit time
      double flip(double y) => _pageH - y;

      void line(double x1, double y1, double x2, double y2) {
        sb.writeln(
            '${x1.toStringAsFixed(2)} ${flip(y1).toStringAsFixed(2)} m ${x2.toStringAsFixed(2)} ${flip(y2).toStringAsFixed(2)} l S');
      }

      void text(String t, double x, double y, double size) {
        // Escape parentheses
        final escaped = t.replaceAll('\\', '\\\\').replaceAll('(', '\\(').replaceAll(')', '\\)');
        sb.writeln('BT /F1 ${size.toStringAsFixed(1)} Tf ${x.toStringAsFixed(2)} ${flip(y).toStringAsFixed(2)} Td ($escaped) Tj ET');
      }

      // Set line width
      sb.writeln('0.8 w');

      double yOffset = _margin;

      // ── Header (first page only) ──────────────────────────────────────
      if (pg == 0) {
        // Title centred
        final titleSize = 20.0;
        final approxTitleW = title.length * titleSize * 0.55;
        text(title, (_pageW - approxTitleW) / 2, yOffset + 18, titleSize);
        // Tempo left
        text('♩= ${tempoBpm.round()} BPM', _margin, yOffset + 18, 11);
        yOffset += headerHeight;
      }

      // ── Draw rows for this page ───────────────────────────────────────
      final int firstRow = pg == 0
          ? 0
          : (rowsPerPage - ((pg == 1 && pg > 0) ? 0 : 0)) +
              (pg - 1) * rowsPerPage +
              rowsPerPage;
      // simpler: first row on this page
      final int pageFirstRow = pg == 0 ? 0 : rowsPerPage + (pg - 1) * rowsPerPage;
      final int pageLastRow = (pageFirstRow + rowsPerPage).clamp(0, totalRows);

      for (int row = pageFirstRow; row < pageLastRow; row++) {
        final double rowTop = yOffset + (row - pageFirstRow) * _rowHeight + 25;
        // Staff top = rowTop + chord text space (20pt)
        final double staffTop = rowTop + 20;

        // Draw 5 staff lines across full usable width
        for (int li = 0; li < 5; li++) {
          final double ly = staffTop + li * _staffLineSpacing;
          line(_margin, ly, _pageW - _margin, ly);
        }

        // Left & right bar lines spanning the staff
        line(_margin, staffTop, _margin, staffTop + _staffHeight);
        line(_pageW - _margin, staffTop, _pageW - _margin, staffTop + _staffHeight);

        // Measure number (left of row, small)
        final int firstMeasure = row * _measuresPerRow;
        text('${firstMeasure + 1}', _margin - 20, staffTop + 2, 7);

        // Measures in this row
        for (int m = 0; m < _measuresPerRow; m++) {
          final int mIndex = row * _measuresPerRow + m;
          if (mIndex >= measures.length) break;

          final double mLeft = _margin + m * measureW;

          // Bar line between measures
          if (m > 0) {
            line(mLeft, staffTop, mLeft, staffTop + _staffHeight);
          }

          // 4 beat slots
          for (int b = 0; b < 4; b++) {
            final double slashCx = mLeft + (b + 0.5) * beatW;
            final double slashTop = staffTop + 2;
            final double slashBot = staffTop + _staffHeight - 2;

            // Slightly thicker slash stroke
            sb.writeln('1.5 w');
            line(slashCx - 4, slashBot, slashCx + 4, slashTop);
            sb.writeln('0.8 w');

            final String chord = measures[mIndex][b];
            if (chord.isNotEmpty) {
              // Position chord name above the staff
              text(chord, slashCx - (chord.length * 3.5), staffTop - 13, 10);
            }
          }
        }
      }

      final streamContent = sb.toString();
      startObj(contentStartId + pg);
      emitLn('<< /Length ${streamContent.length} >>');
      emitLn('stream');
      emit(streamContent);
      emitLn('endstream');
      endObj();
    }

    // ── xref table ───────────────────────────────────────────────────────
    final int xrefOffset = rawBytes.length;
    final int totalObjs = contentStartId + totalPages; // 0-based count
    emitLn('xref');
    emitLn('0 ${totalObjs + 1}');
    emitLn('0000000000 65535 f ');

    // offsets list: index 0 = obj1, index 1 = obj2, etc.
    for (int i = 0; i < totalObjs; i++) {
      if (i < offsets.length) {
        emitLn(offsets[i].toString().padLeft(10, '0') + ' 00000 n ');
      } else {
        emitLn('0000000000 00000 n ');
      }
    }

    emitLn('trailer');
    emitLn('<< /Size ${totalObjs + 1} /Root 1 0 R >>');
    emitLn('startxref');
    emitLn('$xrefOffset');
    emit('%%EOF');

    final tempDir = await getTemporaryDirectory();
    final file = File(
        '${tempDir.path}/chord_sheet_${DateTime.now().millisecondsSinceEpoch}.pdf');
    await file.writeAsBytes(Uint8List.fromList(rawBytes));
    return file;
  }
}