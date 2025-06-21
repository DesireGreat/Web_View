// ignore: unnecessary_import
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

class ImageOverlayService {
  // Original method (keep for backward compatibility)
  static Future<Uint8List> addDetailsOverlay({
    required Uint8List imageBytes,
    Position? position,
    required DateTime timestamp,
    Map<String, dynamic> fieldData = const {},
  }) async {
    return addEnhancedGPSOverlay(
      imageBytes: imageBytes,
      position: position,
      timestamp: timestamp,
      fieldData: fieldData,
      address: '',
    );
  }

  // Enhanced method with GPS camera-like overlay
  static Future<Uint8List> addEnhancedGPSOverlay({
    required Uint8List imageBytes,
    Position? position,
    required DateTime timestamp,
    Map<String, dynamic> fieldData = const {},
    required String address,
  }) async {
    try {
      // Decode the image
      final ui.Codec codec = await ui.instantiateImageCodec(imageBytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image image = frameInfo.image;

      // Create a canvas to draw on
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      final Size imageSize = Size(
        image.width.toDouble(),
        image.height.toDouble(),
      );

      // Draw the original image
      canvas.drawImage(image, Offset.zero, Paint());

      // Calculate overlay dimensions
      final double overlayHeight =
          imageSize.height * 0.25; // 25% of image height
      final double overlayWidth = imageSize.width;

      // Draw semi-transparent black overlay at the bottom
      final Paint overlayPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.8)
        ..style = PaintingStyle.fill;

      canvas.drawRect(
        Rect.fromLTWH(
          0,
          imageSize.height - overlayHeight,
          overlayWidth,
          overlayHeight,
        ),
        overlayPaint,
      );

      // Text styles
      final TextStyle titleStyle = TextStyle(
        color: Colors.white,
        fontSize: _calculateFontSize(imageSize.width, 20),
        fontWeight: FontWeight.bold,
      );

      final TextStyle normalStyle = TextStyle(
        color: Colors.white,
        fontSize: _calculateFontSize(imageSize.width, 16),
      );

      final TextStyle smallStyle = TextStyle(
        color: Colors.white70,
        fontSize: _calculateFontSize(imageSize.width, 14),
      );

      // Starting position for text
      double textY = imageSize.height - overlayHeight + 20;
      final double textX = 20;
      final double lineHeight = _calculateFontSize(imageSize.width, 22);

      // Draw timestamp
      final String formattedDateTime = DateFormat(
        'yyyy-MM-dd HH:mm:ss',
      ).format(timestamp);
      _drawText(
        canvas,
        '📅 $formattedDateTime',
        Offset(textX, textY),
        titleStyle,
      );
      textY += lineHeight;

      // Draw GPS coordinates
      if (position != null) {
        _drawText(
          canvas,
          '📍 GPS: ${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}',
          Offset(textX, textY),
          normalStyle,
        );
        textY += lineHeight;

        // Draw accuracy if available
        _drawText(
          canvas,
          '🎯 Accuracy: ±${position.accuracy.toStringAsFixed(1)}m',
          Offset(textX, textY),
          smallStyle,
        );
        textY += lineHeight * 0.8;
      } else {
        _drawText(
          canvas,
          '📍 GPS: Not Available',
          Offset(textX, textY),
          TextStyle(
            color: Colors.red,
            fontSize: _calculateFontSize(imageSize.width, 16),
          ),
        );
        textY += lineHeight;
      }

      // Draw address
      if (address.isNotEmpty) {
        _drawText(canvas, '🏠 $address', Offset(textX, textY), smallStyle);
        textY += lineHeight * 0.8;
      }

      // Draw field data if available
      if (fieldData.isNotEmpty) {
        _drawText(canvas, '📝 Field Data:', Offset(textX, textY), normalStyle);
        textY += lineHeight * 0.8;

        for (final entry in fieldData.entries) {
          if (textY < imageSize.height - 20) {
            // Ensure we don't go beyond image bounds
            _drawText(
              canvas,
              '  • ${entry.key}: ${entry.value}',
              Offset(textX + 10, textY),
              smallStyle,
            );
            textY += lineHeight * 0.7;
          }
        }
      }

      // Draw border around overlay
      final Paint borderPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      canvas.drawRect(
        Rect.fromLTWH(
          5,
          imageSize.height - overlayHeight + 5,
          overlayWidth - 10,
          overlayHeight - 10,
        ),
        borderPaint,
      );

      // Convert canvas to image
      final ui.Picture picture = recorder.endRecording();
      final ui.Image finalImage = await picture.toImage(
        imageSize.width.toInt(),
        imageSize.height.toInt(),
      );

      // Convert to bytes
      final ByteData? byteData = await finalImage.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData == null) {
        throw Exception('Failed to convert image to bytes');
      }

      return byteData.buffer.asUint8List();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error adding GPS overlay: $e');
      }
      return imageBytes; // Return original image if overlay fails
    }
  }

  static void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style,
  ) {
    final TextPainter textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: ui.TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, offset);
  }

  static double _calculateFontSize(double imageWidth, double baseFontSize) {
    // Scale font size based on image width
    final double scaleFactor = imageWidth / 1000; // Base scale for 1000px width
    return (baseFontSize * scaleFactor).clamp(12.0, 40.0); // Min 12, Max 40
  }
}
