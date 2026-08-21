import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class ChordSheetGenerator {
  static Future<File?> generateAndSaveChordSheet(String title, List<dynamic> chords, double tempoBpm) async {
    final double beatsPerSecond = tempoBpm / 60.0;
    final double secondsPerBeat = 1.0 / beatsPerSecond;
    final double secondsPerMeasure = secondsPerBeat * 4;

    List<List<String>> measures = [];
    if (chords.isEmpty) return null;

    // Chords are Maps with keys 'time' and 'chord'
    // Use the last chord's time + one extra measure as the total length
    double lastTime = (chords.last['time'] as num).toDouble();
    double lastEndTime = lastTime + secondsPerMeasure;

    int totalMeasures = (lastEndTime / secondsPerMeasure).ceil();
    if (totalMeasures == 0) totalMeasures = 1;

    for (int i = 0; i < totalMeasures; i++) {
      measures.add(['', '', '', '']);
    }

    for (var c in chords) {
      final rawTime = c['time'];
      final rawChord = c['chord'];
      if (rawTime == null || rawChord == null) continue;

      double start = (rawTime as num).toDouble();
      String chordName = rawChord.toString();

      int measureIndex = (start / secondsPerMeasure).floor();
      double timeInMeasure = start - (measureIndex * secondsPerMeasure);
      int beatIndex = (timeInMeasure / secondsPerBeat).round().clamp(0, 3);
      if (measureIndex >= 0 && measureIndex < measures.length) {
        measures[measureIndex][beatIndex] = chordName;
      }
    }

    const double pageWidth = 1200;
    const double margin = 100;
    const double staffHeight = 60;
    const double rowSpacing = 200;
    const int measuresPerRow = 4;
    
    int rows = (measures.length / measuresPerRow).ceil();
    if (rows == 0) rows = 1;
    double pageHeight = margin * 2 + (rows * rowSpacing);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, pageWidth, pageHeight));

    final bgPaint = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, pageWidth, pageHeight), bgPaint);

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    textPainter.text = TextSpan(text: title, style: const TextStyle(color: Colors.black, fontSize: 48, fontWeight: FontWeight.bold));
    textPainter.layout();
    textPainter.paint(canvas, Offset((pageWidth - textPainter.width) / 2, margin / 2));

    textPainter.text = TextSpan(text: 'Tempo: ${tempoBpm.round()} BPM', style: const TextStyle(color: Colors.black87, fontSize: 24, fontWeight: FontWeight.bold));
    textPainter.layout();
    textPainter.paint(canvas, Offset(margin, margin / 2 + 20));

    final linePaint = Paint()..color = Colors.black..strokeWidth = 2..style = PaintingStyle.stroke;
    final slashPaint = Paint()..color = Colors.black..strokeWidth = 4..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;

    double currentY = margin + 100;

    for (int r = 0; r < rows; r++) {
      for (int i = 0; i < 5; i++) {
        canvas.drawLine(Offset(margin, currentY + (i * (staffHeight / 4))), Offset(pageWidth - margin, currentY + (i * (staffHeight / 4))), linePaint);
      }
      canvas.drawLine(Offset(margin, currentY), Offset(margin, currentY + staffHeight), linePaint);
      canvas.drawLine(Offset(pageWidth - margin, currentY), Offset(pageWidth - margin, currentY + staffHeight), linePaint);
      
      double measureWidth = (pageWidth - margin * 2) / measuresPerRow;
      
      for (int m = 0; m < measuresPerRow; m++) {
        int mIndex = r * measuresPerRow + m;
        if (mIndex >= measures.length) break;
        double startX = margin + (m * measureWidth);
        
        if (m > 0) canvas.drawLine(Offset(startX, currentY), Offset(startX, currentY + staffHeight), linePaint);
        
        if (m == 0) {
           textPainter.text = TextSpan(text: '${mIndex + 1}', style: const TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.bold));
           textPainter.layout();
           textPainter.paint(canvas, Offset(startX - 40, currentY + 10));
        }

        double beatWidth = measureWidth / 4;
        for (int b = 0; b < 4; b++) {
          double beatX = startX + (b * beatWidth);
          double slashX = beatX + (beatWidth / 2);
          canvas.drawLine(Offset(slashX - 10, currentY + staffHeight - 10), Offset(slashX + 10, currentY + 10), slashPaint);
          
          String chord = measures[mIndex][b];
          if (chord.isNotEmpty && chord != 'N') {
            textPainter.text = TextSpan(text: chord, style: const TextStyle(color: Colors.black, fontSize: 32, fontWeight: FontWeight.bold));
            textPainter.layout();
            textPainter.paint(canvas, Offset(slashX - (textPainter.width / 2), currentY - 45));
          }
        }
      }
      currentY += rowSpacing;
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(pageWidth.toInt(), pageHeight.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return null;
    
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/chord_sheet_${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(byteData.buffer.asUint8List());
    
    return file;
  }
}