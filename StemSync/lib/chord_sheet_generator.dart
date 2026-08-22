import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class ChordSheetGenerator {
  static const double _margin = 45.0;
  static const int _measPerRow = 4;
  static const double _rowH = 86.0;
  static const double _staffLineGap = 5.5;
  static const double _staffH = _staffLineGap * 4;

  static Future<File?> generateAndSaveChordSheet(
    String title,
    String subtitle,
    List<dynamic> chords,
    List<dynamic> lyrics,
    double tempoBpm,
  ) async {
    if (chords.isEmpty) return null;

    final measures = _buildMeasures(chords, tempoBpm);
    if (measures.isEmpty) return null;
    final lyricMeasures = _buildLyricMeasures(lyrics, tempoBpm, measures.length);

    // Load fonts for Hindi and Assamese/Bengali support
    final devanagariData = await rootBundle.load('assets/fonts/NotoSansDevanagari-Regular.ttf');
    final bengaliData = await rootBundle.load('assets/fonts/NotoSansBengali-Regular.ttf');
    final ttfDeva = pw.Font.ttf(devanagariData);
    final ttfBengali = pw.Font.ttf(bengaliData);
    final fontFallback = [ttfDeva, ttfBengali];

    final pdf = pw.Document();

    final double usableW = PdfPageFormat.a4.width - _margin * 2;
    final double measW = usableW / _measPerRow;
    final double beatW = measW / 4;
    final int totalRows = (measures.length / _measPerRow).ceil();

    const double headerH = 52.0;
    final int rowsFirstPage = ((PdfPageFormat.a4.height - _margin * 2 - headerH) / _rowH).floor().clamp(1, 9999);
    final int rowsOtherPage = ((PdfPageFormat.a4.height - _margin * 2) / _rowH).floor().clamp(1, 9999);

    int row = 0;
    while (row < totalRows) {
      final bool isFirst = row == 0;
      final int rowsThisPage = isFirst ? rowsFirstPage : rowsOtherPage;
      final int lastRow = (row + rowsThisPage).clamp(0, totalRows);
      
      final startRow = row;

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(_margin),
          build: (pw.Context context) {
            final children = <pw.Widget>[];

            // Add Text elements
            if (isFirst) {
              children.add(
                pw.Positioned(
                  top: 18,
                  left: 0,
                  right: 0,
                  child: pw.Center(
                    child: pw.Text(title, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, fontFallback: fontFallback)),
                  )
                )
              );
              children.add(
                pw.Positioned(
                  top: 38,
                  left: 0,
                  child: pw.Text('q = ${tempoBpm.round()} BPM', style: pw.TextStyle(fontSize: 10, fontFallback: fontFallback))
                )
              );
              if (subtitle.isNotEmpty) {
                children.add(
                  pw.Positioned(
                    top: 38,
                    right: 0,
                    child: pw.Text(subtitle, style: pw.TextStyle(fontSize: 10, fontFallback: fontFallback))
                  )
                );
              }
            }

            final double topOfRows = isFirst ? headerH : 0;

            for (int r = startRow; r < lastRow; r++) {
              final double rowTop = topOfRows + (r - startRow) * _rowH;
              final double staffTop = rowTop + 24;

              final int firstMeas = r * _measPerRow;
              children.add(
                pw.Positioned(
                  top: staffTop + 5,
                  left: -18,
                  child: pw.Text('${firstMeas + 1}', style: const pw.TextStyle(fontSize: 7))
                )
              );

              for (int m = 0; m < _measPerRow; m++) {
                final int mi = r * _measPerRow + m;
                if (mi >= measures.length) break;

                final double mLeft = m * measW;

                for (int b = 0; b < 4; b++) {
                  final double cx = mLeft + (b + 0.5) * beatW;

                  final String chord = measures[mi][b];
                  if (chord.isNotEmpty) {
                    children.add(
                      pw.Positioned(
                        top: staffTop - 14,
                        left: cx - (chord.length * 5.5) / 2, // Approximate centering
                        child: pw.Text(chord, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, fontFallback: fontFallback))
                      )
                    );
                  }

                  final String lyric = lyricMeasures[mi][b];
                  if (lyric.isNotEmpty) {
                    children.add(
                      pw.Positioned(
                        top: staffTop + _staffH + 12,
                        left: cx - 5,
                        child: pw.Text(lyric, style: pw.TextStyle(fontSize: 8, fontFallback: fontFallback), maxLines: 1)
                      )
                    );
                  }
                }
              }
            }

            // Draw lines using CustomPaint
            children.insert(0, pw.CustomPaint(
              size: const PdfPoint(double.infinity, double.infinity),
              painter: (PdfGraphics canvas, PdfPoint size) {
                // In pw.CustomPaint, (0,0) is bottom-left. We need to invert Y to match top-down.
                double y(double tdY) => size.y - tdY;
                
                void drawLine(double x1, double td1, double x2, double td2, double w) {
                  canvas.setStrokeColor(PdfColors.black);
                  canvas.setLineWidth(w);
                  canvas.drawLine(x1, y(td1), x2, y(td2));
                  canvas.strokePath();
                }

                for (int r = startRow; r < lastRow; r++) {
                  final double rowTop = topOfRows + (r - startRow) * _rowH;
                  final double staffTop = rowTop + 24;

                  for (int li = 0; li < 5; li++) {
                    final double ly = staffTop + li * _staffLineGap;
                    drawLine(0, ly, usableW, ly, 0.5);
                  }

                  drawLine(0, staffTop, 0, staffTop + _staffH, 1.0);
                  drawLine(usableW, staffTop, usableW, staffTop + _staffH, 1.0);

                  for (int m = 0; m < _measPerRow; m++) {
                    final int mi = r * _measPerRow + m;
                    if (mi >= measures.length) break;

                    final double mLeft = m * measW;

                    if (m > 0) {
                      drawLine(mLeft, staffTop, mLeft, staffTop + _staffH, 0.8);
                    }

                    for (int b = 0; b < 4; b++) {
                      final double cx = mLeft + (b + 0.5) * beatW;
                      drawLine(cx - 5, staffTop + _staffH - 3, cx + 5, staffTop + 3, 1.8);
                    }
                  }
                }
              },
            ));

            return pw.Stack(children: children);
          },
        ),
      );
      
      row = lastRow;
    }

    final bytes = await pdf.save();
    
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

  static List<List<String>> _buildMeasures(
      List<dynamic> chords, double tempoBpm) {
    final double spb = 60.0 / tempoBpm;
    final double spm = spb * 4;

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
      if (chord.isEmpty || chord == 'N' || chord == 'N/C' || chord == 'N.C.') continue;

      final double start = (rawTime as num).toDouble();
      final int mi = (start / spm).floor();
      final double tim = start - mi * spm;
      final int bi = (tim / spb).floor().clamp(0, 3);

      if (mi >= 0 && mi < totalMeasures && measures[mi][bi].isEmpty) {
        measures[mi][bi] = chord;
      }
    }

    String lastChord = '';
    for (int mi = 0; mi < totalMeasures; mi++) {
      for (int bi = 0; bi < 4; bi++) {
        String current = measures[mi][bi];
        if (current.isNotEmpty) {
          if (current == lastChord) {
            measures[mi][bi] = '';
          } else {
            lastChord = current;
          }
        }
      }
    }

    return measures;
  }

  static List<List<String>> _buildLyricMeasures(
      List<dynamic> lyrics, double tempoBpm, int totalMeasures) {
    final double spb = 60.0 / tempoBpm;
    final double spm = spb * 4;

    final measures =
        List.generate(totalMeasures, (_) => List.filled(4, '', growable: false));

    for (var l in lyrics) {
      final rawTime = l['time'];
      final text = l['text'];
      if (rawTime == null || text == null) continue;

      // We no longer strip unicode characters!
      String cleanText = text.toString().replaceAll(RegExp(r'<[^>]*>'), '').trim();
      if (cleanText.isEmpty) continue;

      final double start = (rawTime as num).toDouble();
      final int mi = (start / spm).floor();

      if (mi >= 0 && mi < totalMeasures) {
        if (measures[mi][0].isEmpty) {
          measures[mi][0] = cleanText;
        } else {
          measures[mi][0] = "${measures[mi][0]} $cleanText";
        }
      }
    }
    return measures;
  }
}
