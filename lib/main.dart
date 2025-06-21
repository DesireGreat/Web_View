// ignore_for_file: deprecated_member_use, unused_element, unused_import, use_build_context_synchronously, duplicate_ignore, unnecessary_nullable_for_final_variable_declarations
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'location_service.dart';
import 'image_overlay_service.dart';
import 'package:image_picker/image_picker.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:exif/exif.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:xml/xml.dart';
import 'package:archive/archive_io.dart';
import 'package:sqflite/sqflite.dart';
import 'package:geocoding/geocoding.dart';
import 'package:intl/intl.dart';

// Screenshot controller
final ScreenshotController screenshotController = ScreenshotController();

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() => runApp(const MyApp());

// Data models
class PhotoData {
  final String id;
  final String filePath;
  final double? latitude;
  final double? longitude;
  final DateTime timestamp;
  final Map<String, dynamic> fieldData;

  PhotoData({
    required this.id,
    required this.filePath,
    this.latitude,
    this.longitude,
    required this.timestamp,
    this.fieldData = const {},
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'filePath': filePath,
    'latitude': latitude,
    'longitude': longitude,
    'timestamp': timestamp.toIso8601String(),
    'fieldData': json.encode(fieldData),
  };

  factory PhotoData.fromJson(Map<String, dynamic> json) => PhotoData(
    id: json['id'],
    filePath: json['filePath'],
    latitude: json['latitude'],
    longitude: json['longitude'],
    timestamp: DateTime.parse(json['timestamp']),
    fieldData: json['fieldData'] != null ? jsonDecode(json['fieldData']) : {},
  );
}

class FieldForm {
  final String name;
  final List<FieldDefinition> fields;

  FieldForm({required this.name, required this.fields});
}

class FieldDefinition {
  final String name;
  final String type; // 'text', 'number', 'dropdown', 'checkbox', 'date'
  final String label;
  final List<String>? options; // for dropdown
  final bool required;

  FieldDefinition({
    required this.name,
    required this.type,
    required this.label,
    this.options,
    this.required = false,
  });
}

// Database helper
class DatabaseHelper {
  static Database? _database;
  static const String _databaseName = 'gis_app.db';
  static const int _databaseVersion = 1;

  static Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/$_databaseName';

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE photos (
        id TEXT PRIMARY KEY,
        filePath TEXT NOT NULL,
        latitude REAL,
        longitude REAL,
        timestamp TEXT NOT NULL,
        fieldData TEXT
      )
    ''');
  }

  static Future<void> insertPhoto(PhotoData photo) async {
    final db = await database;
    await db.insert(
      'photos',
      photo.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<PhotoData>> getAllPhotos() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('photos');
    return List.generate(maps.length, (i) => PhotoData.fromJson(maps[i]));
  }

  static Future<void> deletePhoto(String id) async {
    final db = await database;
    await db.delete('photos', where: 'id = ?', whereArgs: [id]);
  }
}

// GIS Export Helper
class GISExporter {
  static Future<void> exportToKML(
    List<PhotoData> photos,
    String fileName,
  ) async {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'kml',
      nest: () {
        builder.attribute('xmlns', 'http://www.opengis.net/kml/2.2');
        builder.element(
          'Document',
          nest: () {
            builder.element('name', nest: 'Photo Locations');

            for (final photo in photos) {
              if (photo.latitude != null && photo.longitude != null) {
                builder.element(
                  'Placemark',
                  nest: () {
                    builder.element('name', nest: 'Photo ${photo.id}');
                    builder.element(
                      'description',
                      nest:
                          '''
                Timestamp: ${photo.timestamp}
                Field Data: ${photo.fieldData}
              ''',
                    );
                    builder.element(
                      'Point',
                      nest: () {
                        builder.element(
                          'coordinates',
                          nest: '${photo.longitude},${photo.latitude},0',
                        );
                      },
                    );
                  },
                );
              }
            }
          },
        );
      },
    );

    final document = builder.buildDocument();
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/$fileName.kml');
    await file.writeAsString(document.toXmlString(pretty: true));
  }

  static Future<void> exportToGeoJSON(
    List<PhotoData> photos,
    String fileName,
  ) async {
    final features = photos
        .where((photo) => photo.latitude != null && photo.longitude != null)
        .map(
          (photo) => {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [photo.longitude, photo.latitude],
            },
            'properties': {
              'id': photo.id,
              'timestamp': photo.timestamp.toIso8601String(),
              'fieldData': photo.fieldData,
            },
          },
        )
        .toList();

    final geoJson = {'type': 'FeatureCollection', 'features': features};

    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/$fileName.geojson');
    await file.writeAsString(json.encode(geoJson));
  }

  static Future<void> exportToCSV(
    List<PhotoData> photos,
    String fileName,
  ) async {
    final buffer = StringBuffer();
    buffer.writeln('ID,FilePath,Latitude,Longitude,Timestamp,FieldData');

    for (final photo in photos) {
      buffer.writeln(
        [
          photo.id,
          photo.filePath,
          photo.latitude ?? '',
          photo.longitude ?? '',
          photo.timestamp.toIso8601String(),
          json.encode(photo.fieldData),
        ].join(','),
      );
    }

    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/$fileName.csv');
    await file.writeAsString(buffer.toString());
  }
}

/*class GPSCameraOverlay extends StatefulWidget {
  final Function(XFile?) onImageCaptured;
  final Position? currentPosition;
  final String currentAddress;

  const GPSCameraOverlay({
    super.key,
    required this.onImageCaptured,
    this.currentPosition,
    required this.currentAddress,
  });

  @override
  State<GPSCameraOverlay> createState() => _GPSCameraOverlayState();
}

class _GPSCameraOverlayState extends State<GPSCameraOverlay> {
  final ImagePicker _picker = ImagePicker();
  DateTime _currentTime = DateTime.now();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Update time every second
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentTime = DateTime.now();
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera preview placeholder (you can replace with actual camera widget)
          Container(
            width: double.infinity,
            height: double.infinity,
            color: Colors.black,
            child: const Center(
              child: Text(
                'Camera Preview\n(Tap capture button)',
                style: TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          
          // Top GPS Info Bar
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Date and Time
                  Row(
                    children: [
                      const Icon(Icons.access_time, color: Colors.white, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        DateFormat('yyyy-MM-dd HH:mm:ss').format(_currentTime),
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  
                  // GPS Coordinates
                  Row(
                    children: [
                      Icon(
                        widget.currentPosition != null ? Icons.gps_fixed : Icons.gps_off,
                        color: widget.currentPosition != null ? Colors.green : Colors.red,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.currentPosition != null
                              ? 'GPS: ${widget.currentPosition!.latitude.toStringAsFixed(6)}, ${widget.currentPosition!.longitude.toStringAsFixed(6)}'
                              : 'GPS: Not Available',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  
                  // Address
                  Row(
                    children: [
                      const Icon(Icons.location_on, color: Colors.blue, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.currentAddress.isNotEmpty ? widget.currentAddress : 'Address not available',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          // Capture Button
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _captureImage,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.all(color: Colors.grey, width: 4),
                  ),
                  child: const Icon(
                    Icons.camera_alt,
                    size: 40,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
          
          // Close button
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            right: 10,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _captureImage() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1080,
      );
      
      widget.onImageCaptured(image);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('Error capturing image: $e');
    }
  }
}*/

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GIS Field Collection App',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      home: const WebViewExample(),
    );
  }
}

class WebViewExample extends StatefulWidget {
  const WebViewExample({super.key});

  @override
  State<WebViewExample> createState() => _WebViewExampleState();
}

class _WebViewExampleState extends State<WebViewExample> {
  late final WebViewController _controller;
  String? _latitude;
  String? _longitude;
  bool _isLocationLoading = true;
  DateTime? _lastBackPressTime;
  Position? _currentPosition;

  final PlatformWebViewControllerCreationParams params =
      const PlatformWebViewControllerCreationParams();

  late final WebViewController controller =
      WebViewController.fromPlatformCreationParams(params);

  // Field forms configuration
  final List<FieldForm> _fieldForms = [
    FieldForm(
      name: 'Basic Survey',
      fields: [
        FieldDefinition(
          name: 'site_name',
          type: 'text',
          label: 'Site Name',
          required: true,
        ),
        FieldDefinition(name: 'surveyor', type: 'text', label: 'Surveyor Name'),
        FieldDefinition(
          name: 'weather',
          type: 'dropdown',
          label: 'Weather Conditions',
          options: ['Sunny', 'Cloudy', 'Rainy', 'Foggy'],
        ),
        FieldDefinition(
          name: 'temperature',
          type: 'number',
          label: 'Temperature (°C)',
        ),
        FieldDefinition(name: 'notes', type: 'text', label: 'Additional Notes'),
      ],
    ),
    FieldForm(
      name: 'Environmental Survey',
      fields: [
        FieldDefinition(
          name: 'habitat_type',
          type: 'dropdown',
          label: 'Habitat Type',
          options: ['Forest', 'Grassland', 'Wetland', 'Urban', 'Agricultural'],
        ),
        FieldDefinition(
          name: 'vegetation_cover',
          type: 'dropdown',
          label: 'Vegetation Cover %',
          options: ['0-25%', '26-50%', '51-75%', '76-100%'],
        ),
        FieldDefinition(
          name: 'water_present',
          type: 'checkbox',
          label: 'Water Source Present',
        ),
        FieldDefinition(
          name: 'disturbance',
          type: 'text',
          label: 'Human Disturbance',
        ),
        FieldDefinition(
          name: 'species_observed',
          type: 'text',
          label: 'Species Observed',
        ),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _getLocation();

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: (_) => debugPrint("Page loaded")),
      )
      ..loadRequest(Uri.parse("https://wikipedia.org/"));

    _controller = controller;
  }

  Future<void> _requestPermissions() async {
    try {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.camera,
        Permission.location,
        if (Platform.isAndroid) ...[
          Permission.storage,
          Permission.manageExternalStorage,
        ],
      ].request();

      if (statuses[Permission.camera] == PermissionStatus.denied) {
        debugPrint("Camera permission denied");
      }

      if (statuses[Permission.location] == PermissionStatus.denied) {
        debugPrint("Location permission denied");
      }
    } catch (e) {
      debugPrint("Error requesting permissions: $e");
    }
  }

  Future<void> _getLocation() async {
    try {
      final location = LocationService();
      final position = await location.getCurrentLocation();

      if (!mounted) return;

      setState(() {
        _isLocationLoading = false;
        _currentPosition = position;
        if (position != null) {
          _latitude = position.latitude.toStringAsFixed(6);
          _longitude = position.longitude.toStringAsFixed(6);
        } else {
          _latitude = null;
          _longitude = null;
        }
      });
    } catch (e) {
      debugPrint("Error getting location: $e");
      if (!mounted) return;
      setState(() {
        _isLocationLoading = false;
        _latitude = null;
        _longitude = null;
      });
    }
  }

  void _showLocationDialog() async {
    final address = await _getCurrentAddress();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.location_on, color: Colors.blue),
              SizedBox(width: 8),
              Text("Current Location"),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isLocationLoading)
                const Row(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(width: 16),
                    Text("Fetching location..."),
                  ],
                )
              else if (_latitude != null && _longitude != null) ...[
                const Text(
                  "Coordinates:",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text("Lat: $_latitude"),
                Text("Lng: $_longitude"),
                const SizedBox(height: 12),
                const Text(
                  "Address:",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(address, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    _showMapView();
                  },
                  icon: const Icon(Icons.map),
                  label: const Text("View on Map"),
                ),
              ] else
                const Text("Location not available"),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Close"),
            ),
            if (_latitude == null || _longitude == null)
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _getLocation();
                },
                child: const Text("Retry"),
              ),
          ],
        );
      },
    );
  }

  void _showMapView() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => MapViewScreen(currentPosition: _currentPosition),
      ),
    );
  }

  Future<String> _getAppFolderPath() async {
    try {
      if (Platform.isAndroid) {
        final Directory? externalDir = await getExternalStorageDirectory();
        if (externalDir != null) {
          final Directory appFolder = Directory('${externalDir.path}/Pictures');
          if (!await appFolder.exists()) {
            await appFolder.create(recursive: true);
          }
          return appFolder.path;
        }
      }

      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final Directory appFolder = Directory('${appDocDir.path}/Images');
      if (!await appFolder.exists()) {
        await appFolder.create(recursive: true);
      }
      return appFolder.path;
    } catch (e) {
      debugPrint("Error creating app folder: $e");
      final Directory appDocDir = await getApplicationDocumentsDirectory();
      return appDocDir.path;
    }
  }

  Future<List<File>> _getAppImages() async {
    try {
      final String appFolderPath = await _getAppFolderPath();
      final Directory appFolder = Directory(appFolderPath);

      if (!await appFolder.exists()) {
        return [];
      }

      final List<FileSystemEntity> entities = await appFolder.list().toList();
      final List<File> imageFiles = entities
          .whereType<File>()
          .where(
            (file) =>
                file.path.toLowerCase().endsWith('.jpg') ||
                file.path.toLowerCase().endsWith('.jpeg') ||
                file.path.toLowerCase().endsWith('.png'),
          )
          .toList();

      imageFiles.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );

      return imageFiles;
    } catch (e) {
      debugPrint("Error getting app images: $e");
      return [];
    }
  }

  void _showImageGallery() async {
    final List<File> images = await _getAppImages();

    if (!mounted) return;

    if (images.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No images found in app folder")),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ImageGalleryScreen(images: images),
      ),
    );
  }

  Future<void> _openCamera() async {
    try {
      final cameraStatus = await Permission.camera.status;
      if (!cameraStatus.isGranted) {
        final result = await Permission.camera.request();
        if (!result.isGranted) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Camera permission is required to take photos"),
            ),
          );
          return;
        }
      }

      if (Platform.isAndroid) {
        final storageStatus = await Permission.storage.status;
        if (!storageStatus.isGranted) {
          await Permission.storage.request();
        }
      }

      // Get current address
      //final address = await _getCurrentAddress();

      if (!mounted) return;

      // Use ImagePicker directly with GPS overlay
      final ImagePicker picker = ImagePicker();
      final XFile? capturedImage = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1080,
      );

      if (capturedImage != null && mounted) {
        // Show field data collection form
        final fieldData = await _showFieldDataForm();

        if (mounted) {
          await _saveImageToAppFolder(capturedImage, fieldData ?? {});
        }
      }
    } catch (e) {
      debugPrint("Error opening camera: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error opening camera: ${e.toString()}")),
      );
    }
  }

  Future<Map<String, dynamic>?> _showFieldDataForm() async {
    return await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (BuildContext context) {
        return FieldDataDialog(fieldForms: _fieldForms);
      },
    );
  }

  Future<void> _saveImageToAppFolder(
    XFile pickedFile,
    Map<String, dynamic> fieldData,
  ) async {
    try {
      final String appFolderPath = await _getAppFolderPath();
      final String fileName =
          'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final String filePath = '$appFolderPath/$fileName';

      debugPrint("Attempting to save image to: $filePath");

      final Uint8List imageBytes = await pickedFile.readAsBytes();

      // Add enhanced overlay with GPS details
      Uint8List processedImageBytes;
      try {
        final address = await _getCurrentAddress();
        processedImageBytes = await ImageOverlayService.addEnhancedGPSOverlay(
          imageBytes: imageBytes,
          position: _currentPosition,
          timestamp: DateTime.now(),
          fieldData: fieldData,
          address: address,
        );
      } catch (e) {
        debugPrint("Error adding overlay: $e");
        // Fall back to original image if overlay fails
        processedImageBytes = imageBytes;
      }

      // Add GPS EXIF data if location is available
      if (_currentPosition != null) {
        processedImageBytes = await _addGPSExifData(
          processedImageBytes,
          _currentPosition!,
        );
      }

      final File destinationFile = File(filePath);
      await destinationFile.writeAsBytes(processedImageBytes);

      if (await destinationFile.exists()) {
        debugPrint("Image saved successfully: $filePath");

        // Save photo data to database
        final photoData = PhotoData(
          id: fileName,
          filePath: filePath,
          latitude: _currentPosition?.latitude,
          longitude: _currentPosition?.longitude,
          timestamp: DateTime.now(),
          fieldData: fieldData,
        );

        await DatabaseHelper.insertPhoto(photoData);

        if (!mounted) return;

        // Show success dialog and return to main screen
        await _showImageSavedDialog(destinationFile);
      } else {
        throw Exception("File was not created");
      }
    } catch (e) {
      debugPrint("Error saving image: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to save image: ${e.toString()}")),
      );
    }
  }

  // Enhanced method to get current address
  Future<String> _getCurrentAddress() async {
    if (_currentPosition == null) return 'Location not available';

    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      );

      if (placemarks.isNotEmpty) {
        final placemark = placemarks.first;
        return '${placemark.street ?? ''}, ${placemark.locality ?? ''}, ${placemark.administrativeArea ?? ''}, ${placemark.country ?? ''}';
      }
    } catch (e) {
      debugPrint('Error getting address: $e');
    }

    return 'Address not available';
  }

  Future<Uint8List> _addGPSExifData(
    Uint8List imageBytes,
    Position position,
  ) async {
    try {
      // Note: This is a simplified approach. For production, you might need
      // a more robust EXIF writing library
      return imageBytes; // Placeholder - actual EXIF writing would go here
    } catch (e) {
      debugPrint("Error adding GPS EXIF data: $e");
      return imageBytes;
    }
  }

  Future<void> _showImageSavedDialog(File savedImage) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false, // Prevent dismissing by tapping outside
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text("Success!"),
            ],
          ),
          content: const Text(
            "Your image has been saved with GPS data and field information.",
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                // The camera screen should automatically return to webview
              },
              child: const Text("Continue"),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                _viewSingleImage(savedImage);
              },
              child: const Text("View Image"),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                _showImageGallery();
              },
              child: const Text("View All Images"),
            ),
          ],
        );
      },
    );
  }

  void _viewSingleImage(File imageFile) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ImageViewerScreen(
          imageFile: imageFile,
          onDelete: () {
            setState(() {});
          },
        ),
      ),
    );
  }

  Future<void> _saveScreenshotToDownloads(Uint8List imageBytes) async {
    try {
      final String appFolderPath = await _getAppFolderPath();
      final String filePath =
          '$appFolderPath/webview_capture_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final file = File(filePath);
      await file.writeAsBytes(imageBytes);

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Screenshot saved at: $filePath")));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Failed to save screenshot")),
      );
    }
  }

  Future<void> _printWebPage() async {
    try {
      final image = await screenshotController.capture();
      if (image == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Screenshot failed")));
        return;
      }

      await _saveScreenshotToDownloads(image);

      final doc = pw.Document();
      final imageWidget = pw.MemoryImage(image);

      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (pw.Context context) {
            return pw.Center(child: pw.Image(imageWidget));
          },
        ),
      );

      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => doc.save(),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Failed to print WebView section")),
      );
    }
  }

  /*void _showDataExportDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return DataExportDialog();
      },
    );
  }*/

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        debugPrint("PopScope invoked: $didPop");
      },
      child: WillPopScope(
        onWillPop: () async {
          if (await _controller.canGoBack()) {
            await _controller.goBack();
            return false;
          }

          final now = DateTime.now();
          if (_lastBackPressTime == null ||
              now.difference(_lastBackPressTime!) >
                  const Duration(seconds: 2)) {
            _lastBackPressTime = now;
            if (!mounted) return false;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Press back again to exit")),
            );
            return false;
          }
          return true;
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text("GIS Field Collection"),
            /*actions: [
              IconButton(
                icon: const Icon(Icons.location_on),
                tooltip: "View Location",
                onPressed: _showLocationDialog,
              ),
              IconButton(
                icon: const Icon(Icons.map),
                tooltip: "View Map",
                onPressed: _showMapView,
              ),
              IconButton(
                icon: const Icon(Icons.photo_library),
                tooltip: "View App Images",
                onPressed: _showImageGallery,
              ),
              IconButton(
                icon: const Icon(Icons.download),
                tooltip: "Export Data",
                onPressed: _showDataExportDialog,
              ),
              IconButton(
                icon: const Icon(Icons.print),
                tooltip: "Save & Print WebPage",
                onPressed: _printWebPage,
              ),
            ],*/
          ),
          body: Stack(
            children: [
              Screenshot(
                controller: screenshotController,
                child: WebViewWidget(controller: controller),
              ),
              Positioned(
                bottom: 50,
                left: 20,
                child: FloatingActionButton(
                  backgroundColor: Colors.blue,
                  child: const Icon(Icons.menu),
                  onPressed: () {
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                      ),
                      builder: (BuildContext context) {
                        return Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                leading: const Icon(Icons.location_on),
                                title: const Text("View Location"),
                                subtitle: _isLocationLoading
                                    ? const Text("Loading...")
                                    : (_latitude != null && _longitude != null)
                                    ? Text("Lat: $_latitude, Lng: $_longitude")
                                    : const Text("Location not available"),
                                onTap: () {
                                  Navigator.pop(context);
                                  _showLocationDialog();
                                },
                              ),
                              const Divider(),
                              ListTile(
                                leading: const Icon(Icons.map),
                                title: const Text("View Map"),
                                onTap: () {
                                  Navigator.pop(context);
                                  _showMapView();
                                },
                              ),
                              const Divider(),
                              ListTile(
                                leading: const Icon(Icons.camera_alt),
                                title: const Text("Open Camera"),
                                subtitle: const Text(
                                  "With field data collection",
                                ),
                                onTap: () {
                                  Navigator.pop(context);
                                  _openCamera();
                                },
                              ),
                              const Divider(),
                              ListTile(
                                leading: const Icon(Icons.photo_library),
                                title: const Text("View App Images"),
                                onTap: () {
                                  Navigator.pop(context);
                                  _showImageGallery();
                                },
                              ),
                              /*const Divider(),
                              ListTile(
                                leading: const Icon(Icons.download),
                                title: const Text("Export GIS Data"),
                                onTap: () {
                                  Navigator.pop(context);
                                  _showDataExportDialog();
                                },
                              ),*/
                              const Divider(),
                              ListTile(
                                leading: const Icon(Icons.print),
                                title: const Text("Print"),
                                onTap: () {
                                  Navigator.pop(context);
                                  _printWebPage();
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Field Data Collection Dialog
class FieldDataDialog extends StatefulWidget {
  final List<FieldForm> fieldForms;

  const FieldDataDialog({super.key, required this.fieldForms});

  @override
  State<FieldDataDialog> createState() => _FieldDataDialogState();
}

class _FieldDataDialogState extends State<FieldDataDialog> {
  FieldForm? selectedForm;
  final Map<String, dynamic> formData = {};

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.7,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Field Data Collection',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            if (selectedForm == null) ...[
              Expanded(
                child: ListView.builder(
                  itemCount: widget.fieldForms.length,
                  itemBuilder: (context, index) {
                    final form = widget.fieldForms[index];
                    return ListTile(
                      title: Text(form.name),
                      subtitle: Text('${form.fields.length} fields'),
                      onTap: () {
                        setState(() {
                          selectedForm = form;
                        });
                      },
                    );
                  },
                ),
              ),
            ] else ...[
              Expanded(
                child: ListView.builder(
                  itemCount: selectedForm!.fields.length,
                  itemBuilder: (context, index) {
                    final field = selectedForm!.fields[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: _buildFieldWidget(field),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (selectedForm != null)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        selectedForm = null;
                        formData.clear();
                      });
                    },
                    child: const Text('Back'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: selectedForm == null
                      ? null
                      : () => Navigator.of(context).pop(formData),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFieldWidget(FieldDefinition field) {
    switch (field.type) {
      case 'text':
        return TextFormField(
          decoration: InputDecoration(
            labelText: field.label,
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) => formData[field.name] = value,
        );
      case 'number':
        return TextFormField(
          decoration: InputDecoration(
            labelText: field.label,
            border: const OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          onChanged: (value) => formData[field.name] = double.tryParse(value),
        );
      case 'dropdown':
        return DropdownButtonFormField<String>(
          decoration: InputDecoration(
            labelText: field.label,
            border: const OutlineInputBorder(),
          ),
          items: field.options?.map((option) {
            return DropdownMenuItem<String>(value: option, child: Text(option));
          }).toList(),
          onChanged: (value) => formData[field.name] = value,
        );
      case 'checkbox':
        return CheckboxListTile(
          title: Text(field.label),
          value: formData[field.name] ?? false,
          onChanged: (value) {
            setState(() {
              formData[field.name] = value;
            });
          },
        );
      case 'date':
        return TextFormField(
          decoration: InputDecoration(
            labelText: field.label,
            border: const OutlineInputBorder(),
            suffixIcon: const Icon(Icons.calendar_today),
          ),
          readOnly: true,
          onTap: () async {
            final date = await showDatePicker(
              context: context,
              initialDate: DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (date != null) {
              setState(() {
                formData[field.name] = date.toIso8601String();
              });
            }
          },
          controller: TextEditingController(
            text: formData[field.name] != null
                ? DateTime.parse(formData[field.name]).toString().split(' ')[0]
                : '',
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

// Map View Screen
class MapViewScreen extends StatefulWidget {
  final Position? currentPosition;

  const MapViewScreen({super.key, this.currentPosition});

  @override
  State<MapViewScreen> createState() => _MapViewScreenState();
}

class _MapViewScreenState extends State<MapViewScreen> {
  List<PhotoData> photos = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    try {
      final loadedPhotos = await DatabaseHelper.getAllPhotos();
      setState(() {
        photos = loadedPhotos;
        isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading photos: $e');
      setState(() {
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photo Locations Map'),
        backgroundColor: Colors.green,
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : FlutterMap(
              options: MapOptions(
                initialCenter: widget.currentPosition != null
                    ? LatLng(
                        widget.currentPosition!.latitude,
                        widget.currentPosition!.longitude,
                      )
                    : const LatLng(0, 0),
                initialZoom: 13.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.gis_app',
                ),
                MarkerLayer(
                  markers: [
                    // Current location marker
                    if (widget.currentPosition != null)
                      Marker(
                        width: 80.0,
                        height: 80.0,
                        point: LatLng(
                          widget.currentPosition!.latitude,
                          widget.currentPosition!.longitude,
                        ),
                        child: const Icon(
                          Icons.my_location,
                          color: Colors.blue,
                          size: 30,
                        ),
                      ),
                    // Photo location markers
                    ...photos
                        .where(
                          (photo) =>
                              photo.latitude != null && photo.longitude != null,
                        )
                        .map(
                          (photo) => Marker(
                            width: 80.0,
                            height: 80.0,
                            point: LatLng(photo.latitude!, photo.longitude!),
                            child: GestureDetector(
                              onTap: () => _showPhotoDetails(photo),
                              child: const Icon(
                                Icons.camera_alt,
                                color: Colors.red,
                                size: 25,
                              ),
                            ),
                          ),
                        ),
                    //.toList(),
                  ],
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loadPhotos,
        child: const Icon(Icons.refresh),
      ),
    );
  }

  void _showPhotoDetails(PhotoData photo) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Photo ${photo.id}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Timestamp: ${photo.timestamp}'),
              const SizedBox(height: 8),
              Text('Location: ${photo.latitude}, ${photo.longitude}'),
              const SizedBox(height: 8),
              if (photo.fieldData.isNotEmpty) ...[
                const Text('Field Data:'),
                ...photo.fieldData.entries.map(
                  (entry) => Text('${entry.key}: ${entry.value}'),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _viewPhotoFile(photo);
              },
              child: const Text('View Photo'),
            ),
          ],
        );
      },
    );
  }

  void _viewPhotoFile(PhotoData photo) {
    final file = File(photo.filePath);
    if (file.existsSync()) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ImageViewerScreen(
            imageFile: file,
            onDelete: () {
              _loadPhotos();
            },
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Photo file not found')));
    }
  }
}

// Enhanced Image Gallery Screen
class ImageGalleryScreen extends StatefulWidget {
  final List<File> images;

  const ImageGalleryScreen({super.key, required this.images});

  @override
  State<ImageGalleryScreen> createState() => _ImageGalleryScreenState();
}

class _ImageGalleryScreenState extends State<ImageGalleryScreen> {
  late List<File> _images;
  List<PhotoData> _photoData = [];

  @override
  void initState() {
    super.initState();
    _images = List.from(widget.images);
    _loadPhotoData();
  }

  Future<void> _loadPhotoData() async {
    try {
      final photos = await DatabaseHelper.getAllPhotos();
      setState(() {
        _photoData = photos;
      });
    } catch (e) {
      debugPrint('Error loading photo data: $e');
    }
  }

  void _deleteImage(File imageFile) {
    setState(() {
      _images.remove(imageFile);
    });
  }

  PhotoData? _getPhotoData(File imageFile) {
    return _photoData.firstWhere(
      (photo) => photo.filePath == imageFile.path,
      orElse: () => PhotoData(
        id: '',
        filePath: imageFile.path,
        timestamp: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("App Images (${_images.length})"),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            icon: const Icon(Icons.map),
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (context) => MapViewScreen()));
            },
          ),
        ],
      ),
      body: _images.isEmpty
          ? const Center(
              child: Text("No images found", style: TextStyle(fontSize: 18)),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 0.8,
              ),
              itemCount: _images.length,
              itemBuilder: (context, index) {
                final imageFile = _images[index];
                final photoData = _getPhotoData(imageFile);

                return GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => ImageViewerScreen(
                          imageFile: imageFile,
                          onDelete: () => _deleteImage(imageFile),
                        ),
                      ),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(8),
                            ),
                            child: Image.file(
                              imageFile,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  color: Colors.grey[300],
                                  child: const Icon(
                                    Icons.broken_image,
                                    size: 50,
                                    color: Colors.grey,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(8),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    photoData?.latitude != null
                                        ? Icons.location_on
                                        : Icons.location_off,
                                    size: 16,
                                    color: photoData?.latitude != null
                                        ? Colors.green
                                        : Colors.grey,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      photoData?.latitude != null
                                          ? 'GPS: ${photoData!.latitude!.toStringAsFixed(4)}'
                                          : 'No GPS',
                                      style: const TextStyle(fontSize: 12),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              if (photoData?.fieldData.isNotEmpty == true)
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.notes,
                                      size: 16,
                                      color: Colors.blue,
                                    ),
                                    const SizedBox(width: 4),
                                    const Expanded(
                                      child: Text(
                                        'Field Data',
                                        style: TextStyle(fontSize: 12),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// Enhanced Image Viewer Screen
class ImageViewerScreen extends StatelessWidget {
  final File imageFile;
  final VoidCallback onDelete;

  const ImageViewerScreen({
    super.key,
    required this.imageFile,
    required this.onDelete,
  });

  Future<void> _deleteImage(BuildContext context) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Delete Image"),
          content: const Text(
            "Are you sure you want to delete this image and its associated data?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text("Delete", style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      try {
        // Delete from database
        final fileName = imageFile.path.split('/').last;
        await DatabaseHelper.deletePhoto(fileName);

        // Delete file
        await imageFile.delete();
        onDelete();
        if (context.mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Image and data deleted successfully"),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text("Failed to delete image: $e")));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Image Viewer"),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.info),
            onPressed: () => _showImageInfo(context),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => _deleteImage(context),
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 3.0,
          child: Image.file(
            imageFile,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                color: Colors.grey[800],
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.broken_image, size: 100, color: Colors.white),
                      SizedBox(height: 16),
                      Text(
                        "Unable to load image",
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _showImageInfo(BuildContext context) async {
    try {
      final fileName = imageFile.path.split('/').last;
      final photos = await DatabaseHelper.getAllPhotos();
      final photoData = photos.firstWhere(
        (photo) => photo.id == fileName,
        orElse: () => PhotoData(
          id: fileName,
          filePath: imageFile.path,
          timestamp: imageFile.lastModifiedSync(),
        ),
      );

      if (!context.mounted) return;

      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text("Image Information"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("File: $fileName"),
                const SizedBox(height: 8),
                Text("Timestamp: ${photoData.timestamp}"),
                const SizedBox(height: 8),
                if (photoData.latitude != null &&
                    photoData.longitude != null) ...[
                  Text("GPS: ${photoData.latitude}, ${photoData.longitude}"),
                  const SizedBox(height: 8),
                ] else
                  const Text("GPS: Not available"),
                if (photoData.fieldData.isNotEmpty) ...[
                  const Text("Field Data:"),
                  ...photoData.fieldData.entries.map(
                    (entry) => Text("${entry.key}: ${entry.value}"),
                  ),
                ] else
                  const Text("Field Data: None"),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text("Close"),
              ),
            ],
          );
        },
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error loading image info: $e")));
    }
  }
}
