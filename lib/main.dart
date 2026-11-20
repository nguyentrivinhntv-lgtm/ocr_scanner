import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image/image.dart' as img;

void main() => runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Scan Tài Liệu & Hồ Sơ',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const MainNavigationScreen(),
    ));

/// Model đại diện cho một Hồ Sơ đã lưu
class SavedProfile {
  final String id;
  final String title;
  final String createdAt;
  final List<String> imagePaths;
  final String pdfPath;
  final String ocrText;

  SavedProfile({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.imagePaths,
    required this.pdfPath,
    required this.ocrText,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'imagePaths': imagePaths,
        'pdfPath': pdfPath,
        'ocrText': ocrText,
      };

  factory SavedProfile.fromJson(Map<String, dynamic> json) => SavedProfile(
        id: json['id'] ?? '',
        title: json['title'] ?? 'Hồ sơ không tên',
        createdAt: json['createdAt'] ?? '',
        imagePaths: List<String>.from(json['imagePaths'] ?? []),
        pdfPath: json['pdfPath'] ?? '',
        ocrText: json['ocrText'] ?? '',
      );
}

/// Quản lý dữ liệu lưu trữ hồ sơ bằng file JSON cục bộ
class ProfileStorage {
  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/profiles_data.json');
  }

  static Future<List<SavedProfile>> loadProfiles() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      final List<dynamic> list = jsonDecode(content);
      return list.map((e) => SavedProfile.fromJson(e)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveProfiles(List<SavedProfile> profiles) async {
    final file = await _getFile();
    final jsonStr = jsonEncode(profiles.map((e) => e.toJson()).toList());
    await file.writeAsString(jsonStr);
  }

  static Future<void> deleteProfile(SavedProfile profile) async {
    final list = await loadProfiles();
    list.removeWhere((p) => p.id == profile.id);
    await saveProfiles(list);

    // Xóa các file vật lý của hồ sơ
    try {
      for (final p in profile.imagePaths) {
        final f = File(p);
        if (await f.exists()) await f.delete();
      }
      final pdfF = File(profile.pdfPath);
      if (await pdfF.exists()) await pdfF.delete();
    } catch (_) {}
  }
}

/// Màn hình điều hướng chính với 2 Tab: Quét mới & Hồ sơ đã lưu
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  final GlobalKey<_ProfilesTabState> _profilesKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          ScanTab(
            onSavedSuccess: () {
              setState(() => _currentIndex = 1);
              _profilesKey.currentState?.reload();
            },
          ),
          ProfilesTab(key: _profilesKey),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) {
          setState(() => _currentIndex = idx);
          if (idx == 1) {
            _profilesKey.currentState?.reload();
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.document_scanner_outlined),
            selectedIcon: Icon(Icons.document_scanner),
            label: 'Quét mới',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Hồ sơ đã lưu',
          ),
        ],
      ),
    );
  }
}

/// TAB 1: Quét tài liệu, Bắt viền, Bộ lọc tương phản, OCR & Lưu hồ sơ
class ScanTab extends StatefulWidget {
  final VoidCallback onSavedSuccess;
  const ScanTab({super.key, required this.onSavedSuccess});

  @override
  State<ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<ScanTab> {
  final _picker = ImagePicker();
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  final List<String> _pages = [];
  String _text = '';
  bool _loading = false;
  int _currentPage = 0;
  int _imageKeyCounter = 0;

  /// Quét tài liệu với Google ML Kit Scanner Full Mode:
  /// - Tự động phát hiện 4 góc trang giấy
  /// - Làm tối vùng nền bên ngoài để nổi bật tài liệu
  /// - Chống rung và giữ cố định điểm bắt góc
  Future<void> _scanDocument() async {
    try {
      final result = await CunningDocumentScanner.scanDocuments(
        noOfPages: 100,
        scannerSource: ScannerSource.cameraAndGallery,
        output: ScanOutput.images,
        androidScannerMode: AndroidScannerMode.full,
      );
      if (result != null && result.images.isNotEmpty) {
        setState(() {
          _pages.addAll(result.images);
          _currentPage = _pages.length - result.images.length;
          _imageKeyCounter++;
        });
        _ocrAllPages();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi scan: $e')),
        );
      }
    }
  }

  /// Chế độ chụp liên tục bằng Camera:
  /// Chụp trang 1 -> tự động mở tiếp camera chụp trang 2 -> trang 3... cho đến khi người dùng bấm Hủy/Xong
  Future<void> _batchCameraScan() async {
    int count = 0;
    while (true) {
      try {
        final photo = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 95,
        );
        if (photo == null) {
          // Người dùng bấm nút quay lại hoặc hủy chụp
          break;
        }
        setState(() {
          _pages.add(photo.path);
          _currentPage = _pages.length - 1;
          _imageKeyCounter++;
        });
        count++;
      } catch (e) {
        break;
      }
    }
    if (count > 0) {
      _ocrAllPages();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('📸 Đã thêm $count ảnh chụp liên tục')),
        );
      }
    }
  }

  /// Hiển thị menu thêm trang nhanh
  void _showAddOptionsSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.document_scanner, color: Colors.indigo),
                title: const Text('Quét bắt viền (Tự nhận diện 4 góc)'),
                subtitle: const Text('Chụp lần lượt từng trang, tự cắt mép giấy'),
                onTap: () {
                  Navigator.pop(ctx);
                  _scanDocument();
                },
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Colors.teal),
                title: const Text('Chụp liên tục (Nhiều trang không gián đoạn)'),
                subtitle: const Text('Chụp xong tự mở tiếp trang sau liền tay'),
                onTap: () {
                  Navigator.pop(ctx);
                  _batchCameraScan();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: Colors.blueGrey),
                title: const Text('Chọn từ thư viện ảnh'),
                subtitle: const Text('Chọn một hoặc nhiều ảnh có sẵn'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickFromGallery();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
    try {
      // Dùng Document Scanner với nguồn từ Thư viện: tự động nhận diện viền 4 góc và cho phép kéo chỉnh
      final result = await CunningDocumentScanner.scanDocuments(
        noOfPages: 100,
        scannerSource: ScannerSource.gallery,
        output: ScanOutput.images,
        androidScannerMode: AndroidScannerMode.full,
      );
      if (result != null && result.images.isNotEmpty) {
        setState(() {
          _pages.addAll(result.images);
          _currentPage = _pages.length - result.images.length;
          _imageKeyCounter++;
        });
        _ocrAllPages();
      }
    } catch (e) {
      // Fallback nếu thư viện ảnh hệ thống cần image_picker
      try {
        final picked = await _picker.pickMultiImage(imageQuality: 95);
        if (picked.isNotEmpty) {
          setState(() {
            _pages.addAll(picked.map((f) => f.path));
            _currentPage = _pages.length - picked.length;
            _imageKeyCounter++;
          });
          _ocrAllPages();
        }
      } catch (err) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Lỗi chọn từ thư viện: $err')),
          );
        }
      }
    }
  }

  /// Áp dụng bộ lọc tài liệu: Magic Enhance (làm sáng nền, đậm chữ) hoặc B&W (đen trắng)
  Future<void> _applyDocumentFilter(String filterMode) async {
    if (_pages.isEmpty) return;
    setState(() => _loading = true);

    try {
      final path = _pages[_currentPage];
      final bytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);

      if (decoded != null) {
        img.Image processed;
        if (filterMode == 'bw') {
          // Chế độ Đen trắng scan rõ chữ
          processed = img.grayscale(decoded);
          processed = img.contrast(processed, contrast: 150);
        } else if (filterMode == 'magic') {
          // Chế độ Magic Color: Tăng tương phản, làm trắng giấy, đậm mực
          processed = img.contrast(decoded, contrast: 135);
          processed = img.adjustColor(processed, brightness: 1.12);
        } else {
          processed = decoded;
        }

        final encoded = img.encodeJpg(processed, quality: 95);
        await File(path).writeAsBytes(encoded);

        // Xóa cache ảnh để Flutter hiển thị ngay ảnh mới
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();

        setState(() {
          _imageKeyCounter++;
        });

        await _ocrAllPages();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(filterMode == 'magic'
                  ? '✨ Đã tối ưu nét chữ và làm sáng nền giấy'
                  : '📄 Đã chuyển sang chế độ quét Đen Trắng'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi áp dụng bộ lọc: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _ocrAllPages() async {
    setState(() => _loading = true);
    final buffer = StringBuffer();
    for (int i = 0; i < _pages.length; i++) {
      final result = await _recognizer
          .processImage(InputImage.fromFilePath(_pages[i]));
      if (result.text.isNotEmpty) {
        buffer.writeln('--- Trang ${i + 1} ---');
        buffer.writeln(result.text);
        buffer.writeln();
      }
    }
    setState(() {
      _text = buffer.toString().trim();
      _loading = false;
    });
  }

  Future<File> _generatePdfFile(String targetDir, String fileName) async {
    final pdf = pw.Document();
    for (final pagePath in _pages) {
      final imageBytes = await File(pagePath).readAsBytes();
      final image = pw.MemoryImage(imageBytes);
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
        ),
      );
    }
    final file = File('$targetDir/$fileName');
    await file.writeAsBytes(await pdf.save());
    return file;
  }

  Future<void> _sharePdfQuick() async {
    if (_pages.isEmpty) return;
    setState(() => _loading = true);
    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = await _generatePdfFile(tempDir.path, 'scan_$timestamp.pdf');
      setState(() => _loading = false);
      SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi: $e')));
      }
    }
  }

  Future<void> _saveToProfiles() async {
    if (_pages.isEmpty) return;

    final now = DateTime.now();
    final defaultName =
        'Hồ sơ ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final textController = TextEditingController(text: defaultName);

    final confirmedTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.save_as, color: Colors.indigo),
            SizedBox(width: 8),
            Text('Lưu vào Hồ Sơ'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Đặt tên cho hồ sơ này:'),
            const SizedBox(height: 8),
            TextField(
              controller: textController,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'VD: Căn cước công dân, Hóa đơn...',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Bao gồm ${_pages.length} trang và nội dung OCR đã nhận diện.',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, textController.text.trim()),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );

    if (confirmedTitle == null || confirmedTitle.isEmpty) return;

    setState(() => _loading = true);

    try {
      final docDir = await getApplicationDocumentsDirectory();
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final profileDir = Directory('${docDir.path}/profiles/$id');
      await profileDir.create(recursive: true);

      final savedImagePaths = <String>[];
      for (int i = 0; i < _pages.length; i++) {
        final originalFile = File(_pages[i]);
        final ext = originalFile.path.split('.').last;
        final targetPath = '${profileDir.path}/page_${i + 1}.$ext';
        await originalFile.copy(targetPath);
        savedImagePaths.add(targetPath);
      }

      final pdfFile = await _generatePdfFile(profileDir.path, 'document.pdf');

      final newProfile = SavedProfile(
        id: id,
        title: confirmedTitle,
        createdAt:
            '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
        imagePaths: savedImagePaths,
        pdfPath: pdfFile.path,
        ocrText: _text,
      );

      final currentList = await ProfileStorage.loadProfiles();
      currentList.insert(0, newProfile);
      await ProfileStorage.saveProfiles(currentList);

      setState(() {
        _loading = false;
        _pages.clear();
        _text = '';
        _currentPage = 0;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Đã lưu hồ sơ thành công!'),
            backgroundColor: Colors.green,
          ),
        );
        widget.onSavedSuccess();
      }
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi lưu hồ sơ: $e')),
        );
      }
    }
  }

  void _deletePage(int index) {
    setState(() {
      _pages.removeAt(index);
      if (_currentPage >= _pages.length && _pages.isNotEmpty) {
        _currentPage = _pages.length - 1;
      }
      _imageKeyCounter++;
    });
    if (_pages.isNotEmpty) {
      _ocrAllPages();
    } else {
      setState(() => _text = '');
    }
  }

  @override
  void dispose() {
    _recognizer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📄 Quét Tài Liệu Mới'),
        actions: [
          if (_pages.isNotEmpty)
            IconButton(
              onPressed: () => setState(() {
                _pages.clear();
                _text = '';
                _currentPage = 0;
                _imageKeyCounter++;
              }),
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Hủy làm mới',
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: FilledButton.icon(
                    onPressed: _scanDocument,
                    icon: const Icon(Icons.document_scanner),
                    label: const Text('Scan bắt viền'),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: FilledButton.tonalIcon(
                    onPressed: _batchCameraScan,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Chụp liên tục'),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.outlined(
                  onPressed: _pickFromGallery,
                  icon: const Icon(Icons.photo_library),
                  tooltip: 'Thư viện',
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_pages.isNotEmpty) ...[
              // Dải thumbnail các trang + Nút thêm trang nhanh
              SizedBox(
                height: 75,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _pages.length + 1,
                  itemBuilder: (context, index) {
                    if (index == _pages.length) {
                      return GestureDetector(
                        onTap: _showAddOptionsSheet,
                        child: Container(
                          width: 60,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: Colors.indigo.shade50,
                            border: Border.all(
                              color: Colors.indigo.shade300,
                              style: BorderStyle.solid,
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add, color: Colors.indigo, size: 22),
                                SizedBox(height: 2),
                                Text(
                                  '+ Thêm',
                                  style: TextStyle(
                                    color: Colors.indigo,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    final isSelected = index == _currentPage;
                    return GestureDetector(
                      onTap: () => setState(() => _currentPage = index),
                      onLongPress: () => _deletePage(index),
                      child: Container(
                        width: 60,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isSelected ? Colors.indigo : Colors.grey.shade300,
                            width: isSelected ? 3 : 1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.file(
                                File(_pages[index]),
                                key: ValueKey('${_pages[index]}_$_imageKeyCounter'),
                                fit: BoxFit.cover,
                              ),
                            ),
                            Positioned(
                              bottom: 2,
                              right: 2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(color: Colors.white, fontSize: 10),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Trang ${_currentPage + 1} / ${_pages.length}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  // Thanh công cụ bộ lọc làm nét chữ / sáng nền giấy
                  Row(
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: _loading ? null : () => _applyDocumentFilter('magic'),
                        icon: const Icon(Icons.auto_fix_high, size: 16, color: Colors.indigo),
                        label: const Text('Làm nét chữ', style: TextStyle(fontSize: 12)),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: _loading ? null : () => _applyDocumentFilter('bw'),
                        icon: const Icon(Icons.contrast, size: 16, color: Colors.blueGrey),
                        label: const Text('Đen trắng', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Ảnh lớn trang hiện tại (chạm để phóng to)
              Expanded(
                flex: 3,
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => FullScreenImageViewer(
                          imagePaths: _pages,
                          initialIndex: _currentPage,
                        ),
                      ),
                    );
                  },
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: double.infinity,
                          color: Colors.black.withOpacity(0.04),
                          child: Image.file(
                            File(_pages[_currentPage]),
                            key: ValueKey('${_pages[_currentPage]}_$_imageKeyCounter'),
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.all(8),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.zoom_in, color: Colors.white, size: 14),
                            SizedBox(width: 4),
                            Text(
                              'Chạm phóng to',
                              style: TextStyle(color: Colors.white, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_pages.isEmpty && _text.isEmpty)
              const Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.document_scanner, size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text(
                        'Nhấn "Scan bắt viền" để quét tài liệu\nCamera sẽ tự nhận diện 4 góc & làm tối nền ngoài',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            if (_loading) const LinearProgressIndicator(),
            if (_text.isNotEmpty) ...[
              const SizedBox(height: 8),
              Expanded(
                flex: 2,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(_text),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (_pages.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.teal.shade700,
                      ),
                      onPressed: _loading ? null : _saveToProfiles,
                      icon: const Icon(Icons.bookmark_add),
                      label: const Text('Lưu hồ sơ'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: _loading ? null : _sharePdfQuick,
                    icon: const Icon(Icons.picture_as_pdf),
                    tooltip: 'Chia sẻ PDF',
                  ),
                  if (_text.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    IconButton.filledTonal(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Đã copy văn bản')),
                        );
                      },
                      icon: const Icon(Icons.copy),
                      tooltip: 'Copy text',
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// TAB 2: Danh sách và quản lý Hồ Sơ đã lưu
class ProfilesTab extends StatefulWidget {
  const ProfilesTab({super.key});

  @override
  State<ProfilesTab> createState() => _ProfilesTabState();
}

class _ProfilesTabState extends State<ProfilesTab> {
  List<SavedProfile> _profiles = [];
  String _searchQuery = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  void reload() async {
    setState(() => _loading = true);
    final list = await ProfileStorage.loadProfiles();
    if (mounted) {
      setState(() {
        _profiles = list;
        _loading = false;
      });
    }
  }

  List<SavedProfile> get _filteredProfiles {
    if (_searchQuery.isEmpty) return _profiles;
    final q = _searchQuery.toLowerCase();
    return _profiles
        .where((p) => p.title.toLowerCase().contains(q) || p.ocrText.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📁 Hồ Sơ Đã Lưu'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              onChanged: (val) => setState(() => _searchQuery = val),
              decoration: InputDecoration(
                hintText: 'Tìm kiếm hồ sơ hoặc nội dung chữ...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _searchQuery = ''),
                      )
                    : null,
                filled: true,
                fillColor: Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: _filteredProfiles.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_open, size: 64, color: Colors.grey.shade400),
                        const SizedBox(height: 12),
                        Text(
                          _searchQuery.isEmpty
                              ? 'Chưa có hồ sơ nào được lưu.\nHãy chuyển sang tab "Quét mới" để lưu tài liệu.'
                              : 'Không tìm thấy hồ sơ phù hợp.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _filteredProfiles.length,
                    itemBuilder: (context, index) {
                      final item = _filteredProfiles[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        elevation: 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ProfileDetailScreen(profile: item),
                              ),
                            );
                            reload();
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    width: 60,
                                    height: 80,
                                    color: Colors.grey.shade200,
                                    child: item.imagePaths.isNotEmpty
                                        ? Image.file(
                                            File(item.imagePaths.first),
                                            fit: BoxFit.cover,
                                            errorBuilder: (context, error, stackTrace) =>
                                                const Icon(Icons.broken_image),
                                          )
                                        : const Icon(Icons.picture_as_pdf),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          const Icon(Icons.calendar_today,
                                              size: 13, color: Colors.grey),
                                          const SizedBox(width: 4),
                                          Text(
                                            item.createdAt,
                                            style: const TextStyle(
                                                fontSize: 12, color: Colors.grey),
                                          ),
                                          const SizedBox(width: 12),
                                          const Icon(Icons.pages,
                                              size: 13, color: Colors.grey),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${item.imagePaths.length} trang',
                                            style: const TextStyle(
                                                fontSize: 12, color: Colors.grey),
                                          ),
                                        ],
                                      ),
                                      if (item.ocrText.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          item.ocrText.replaceAll('\n', ' '),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey.shade700,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right, color: Colors.grey),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Màn hình Xem Chi Tiết một Hồ Sơ
class ProfileDetailScreen extends StatefulWidget {
  final SavedProfile profile;
  const ProfileDetailScreen({super.key, required this.profile});

  @override
  State<ProfileDetailScreen> createState() => _ProfileDetailScreenState();
}

class _ProfileDetailScreenState extends State<ProfileDetailScreen> {
  int _selectedImage = 0;

  void _sharePdf() {
    final pdfFile = File(widget.profile.pdfPath);
    if (pdfFile.existsSync()) {
      SharePlus.instance.share(ShareParams(files: [XFile(pdfFile.path)]));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không tìm thấy file PDF trên thiết bị')),
      );
    }
  }

  void _deleteProfile() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xác nhận xóa hồ sơ'),
        content: Text('Bạn có chắc chắn muốn xóa "${widget.profile.title}"? Dữ liệu và file PDF sẽ bị xóa khỏi máy.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa vĩnh viễn'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ProfileStorage.deleteProfile(widget.profile);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã xóa hồ sơ')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    return Scaffold(
      appBar: AppBar(
        title: Text(profile.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Chia sẻ PDF',
            onPressed: _sharePdf,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            tooltip: 'Xóa hồ sơ',
            onPressed: _deleteProfile,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.indigo),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Ngày lưu: ${profile.createdAt}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('Tổng số trang: ${profile.imagePaths.length} trang'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (profile.imagePaths.isNotEmpty) ...[
              const Text('Các trang tài liệu:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              SizedBox(
                height: 80,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: profile.imagePaths.length,
                  itemBuilder: (context, idx) {
                    final isSel = idx == _selectedImage;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedImage = idx),
                      child: Container(
                        width: 60,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isSel ? Colors.indigo : Colors.grey.shade300,
                            width: isSel ? 3 : 1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            File(profile.imagePaths[idx]),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FullScreenImageViewer(
                        imagePaths: profile.imagePaths,
                        initialIndex: _selectedImage,
                      ),
                    ),
                  );
                },
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        height: 280,
                        width: double.infinity,
                        color: Colors.black.withOpacity(0.04),
                        child: Image.file(
                          File(profile.imagePaths[_selectedImage]),
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.all(8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.65),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.zoom_in, color: Colors.white, size: 15),
                          SizedBox(width: 4),
                          Text(
                            'Chạm phóng to',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Văn bản nhận diện (OCR):',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                if (profile.ocrText.isNotEmpty)
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: profile.ocrText));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Đã copy văn bản vào clipboard')),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                profile.ocrText.isEmpty ? 'Không có văn bản nào được nhận diện.' : profile.ocrText,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _sharePdf,
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('Mở & Chia sẻ File PDF'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Màn hình Xem ảnh toàn màn hình với Phóng to / Thu nhỏ (Pinch-to-Zoom & Pan)
class FullScreenImageViewer extends StatefulWidget {
  final List<String> imagePaths;
  final int initialIndex;

  const FullScreenImageViewer({
    super.key,
    required this.imagePaths,
    this.initialIndex = 0,
  });

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.8),
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          'Trang ${_currentIndex + 1} / ${widget.imagePaths.length}',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.imagePaths.length,
        onPageChanged: (idx) => setState(() => _currentIndex = idx),
        itemBuilder: (context, index) {
          return Center(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 6.0,
              clipBehavior: Clip.none,
              child: Image.file(
                File(widget.imagePaths[index]),
                fit: BoxFit.contain,
              ),
            ),
          );
        },
      ),
    );
  }
}

