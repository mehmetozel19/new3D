import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../../models/houses_store.dart';
import '../../../features/panorama/theme/ui_styles.dart';
import '../../../models/editor_models.dart';
import 'room_editor_page.dart';
import '../../../models/panorama_data.dart';





// ============================================================================
// AI CLASSIFIER
// ============================================================================

class AIClassifier {
  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;

  // 2 adet kalıcı resim worker'ı
  final List<_ImagePrepareWorker> _workers = [];

  int _nextWorker = 0;

  // Aynı interpreter'a iki inference'ın aynı anda girmesini engeller.
  Future<void> _inferenceTail = Future<void>.value();

  Future<void>? _loadingFuture;

  final List<String> labels = [
    'backyard',
    'bathroom',
    'bedroom',
    'frontyard',
    'kitchen',
    'livingRoom',
  ];


  // ==========================================================================
  // MODEL + WORKER'LARI YÜKLE
  // ==========================================================================

  Future<void> loadModel() {
    // Aynı anda birden fazla loadModel çağrılırsa
    // tek yükleme işlemini paylaş.
    return _loadingFuture ??= _loadEverything();
  }


  Future<void> _loadEverything() async {
    try {
      // ----------------------------------------------------------------------
      // TFLITE MODEL
      // ----------------------------------------------------------------------

      _interpreter = await Interpreter.fromAsset(
        'assets/room_model.tflite',
      );

      _isolateInterpreter = await IsolateInterpreter.create(
        address: _interpreter!.address,
      );


      debugPrint('======================================');
      debugPrint('MODEL YÜKLENDİ');

      debugPrint(
        'INPUT SHAPE : ${_interpreter!.getInputTensor(0).shape}',
      );

      debugPrint(
        'INPUT TYPE  : ${_interpreter!.getInputTensor(0).type}',
      );

      debugPrint(
        'OUTPUT SHAPE: ${_interpreter!.getOutputTensor(0).shape}',
      );

      debugPrint(
        'OUTPUT TYPE : ${_interpreter!.getOutputTensor(0).type}',
      );


      // ----------------------------------------------------------------------
      // 2 KALICI IMAGE WORKER
      // ----------------------------------------------------------------------

      if (_workers.isEmpty) {
        final worker1 = _ImagePrepareWorker();
        final worker2 = _ImagePrepareWorker();

        await Future.wait([
          worker1.start(),
          worker2.start(),
        ]);

        _workers.add(worker1);
        _workers.add(worker2);
      }

      debugPrint(
        'IMAGE WORKER SAYISI: ${_workers.length}',
      );

      debugPrint('======================================');
    } catch (e, stackTrace) {
      debugPrint('AI başlatma hatası: $e');
      debugPrint('$stackTrace');

      _loadingFuture = null;

      rethrow;
    }
  }


  // ==========================================================================
  // TEK RESİM SINIFLANDIR
  // ==========================================================================

  Future<String> classifyImage(
      String imagePath,
      ) async {
    await loadModel();

    if (_interpreter == null ||
        _isolateInterpreter == null ||
        _workers.isEmpty) {
      return 'Model yok';
    }

    try {
      // ----------------------------------------------------------------------
      // WORKER SEÇ
      // ----------------------------------------------------------------------

      final worker = _workers[
      _nextWorker % _workers.length
      ];

      _nextWorker++;


      // ----------------------------------------------------------------------
      // BÜYÜK RESİM:
      //
      // 8K JPEG
      //   ↓
      // background worker
      //   ↓
      // decode
      //   ↓
      // 224 x 224
      //   ↓
      // Float32 RGB
      //
      // UI bu sırada bloklanmaz.
      // ----------------------------------------------------------------------

      final Float32List inputBuffer =
      await worker.prepareImage(
        imagePath,
      );


      // ----------------------------------------------------------------------
      // [1,224,224,3]
      // ----------------------------------------------------------------------

      final input = inputBuffer.reshape(
        [1, 224, 224, 3],
      );


      // ----------------------------------------------------------------------
      // [1,6]
      // ----------------------------------------------------------------------

      final output =
      List<double>.filled(
        labels.length,
        0.0,
      ).reshape(
        [1, labels.length],
      );


      // ----------------------------------------------------------------------
      // INFERENCE
      //
      // Interpreter aynı anda yalnızca tek inference çalıştıracak.
      // ----------------------------------------------------------------------

      final results =
      await _runInferenceLocked(
        input,
        output,
      );


      // ----------------------------------------------------------------------
      // EN YÜKSEK SONUÇ
      // ----------------------------------------------------------------------

      int bestIndex = 0;

      for (int i = 1;
      i < results.length;
      i++) {
        if (results[i] >
            results[bestIndex]) {
          bestIndex = i;
        }
      }


      final confidence =
          results[bestIndex] * 100;


      debugPrint('--------------------------------');

      for (int i = 0;
      i < labels.length;
      i++) {
        debugPrint(
          '${labels[i]} : '
              '${results[i].toStringAsFixed(5)}',
        );
      }

      debugPrint(
        'TAHMİN = ${labels[bestIndex]} '
            '%${confidence.toStringAsFixed(2)}',
      );

      debugPrint('--------------------------------');


      return labels[bestIndex];
    } catch (e, stackTrace) {
      debugPrint(
        'AI sınıflandırma hatası: $e',
      );

      debugPrint('$stackTrace');

      return 'backyard';
    }
  }


  // ==========================================================================
  // TFLITE INFERENCE LOCK
  // ==========================================================================

  Future<List<double>> _runInferenceLocked(
      Object input,
      dynamic output,
      ) async {
    // Önceki inference tamamlanana kadar bekle.
    final previous =
        _inferenceTail;

    final release =
    Completer<void>();

    _inferenceTail =
        release.future;


    await previous;


    try {
      await _isolateInterpreter!.run(
        input,
        output,
      );

      return List<double>.from(
        output[0],
      );
    } finally {
      release.complete();
    }
  }


  // ==========================================================================
  // TOPLU SINIFLANDIRMA
  //
  // Aynı anda en fazla 2 görüntü hazırlıyoruz.
  // ==========================================================================

  Future<List<String>> classifyImages(
      List<String> imagePaths, {
        void Function(
            int completed,
            int total,
            String currentPath,
            )? onProgress,
      }) async {
    await loadModel();

    final results =
    List<String>.filled(
      imagePaths.length,
      'backyard',
    );


    // ------------------------------------------------------------------------
    // 2'Lİ GRUPLAR
    // ------------------------------------------------------------------------

    for (int start = 0;
    start < imagePaths.length;
    start += 2) {

      final end =
      (start + 2 < imagePaths.length)
          ? start + 2
          : imagePaths.length;


      final futures =
      <Future<void>>[];


      for (int i = start;
      i < end;
      i++) {

        futures.add(
              () async {
            final path =
            imagePaths[i];

            final prediction =
            await classifyImage(path);

            results[i] =
                prediction;

            onProgress?.call(
              i + 1,
              imagePaths.length,
              path,
            );
          }(),
        );
      }


      // İki resmin işi bitmeden
      // sonraki iki resmi başlatma.
      await Future.wait(
        futures,
      );


      // UI'ya frame fırsatı ver.
      await Future<void>.delayed(
        Duration.zero,
      );
    }


    return results;
  }


  // ==========================================================================
  // KAPAT
  // ==========================================================================

  Future<void> dispose() async {
    // Önce image worker'ları kapat.
    for (final worker in _workers) {
      await worker.dispose();
    }

    _workers.clear();


    try {
      await _isolateInterpreter?.close();
    } catch (e) {
      debugPrint(
        'IsolateInterpreter kapatma hatası: $e',
      );
    }


    try {
      _interpreter?.close();
    } catch (e) {
      debugPrint(
        'Interpreter kapatma hatası: $e',
      );
    }


    _isolateInterpreter = null;
    _interpreter = null;
    _loadingFuture = null;
  }
}


// ============================================================================
// KALICI IMAGE WORKER
// ============================================================================

class _ImagePrepareWorker {
  Isolate? _isolate;
  SendPort? _sendPort;


  Future<void> start() async {
    if (_sendPort != null) {
      return;
    }


    final readyPort =
    ReceivePort();


    _isolate =
    await Isolate.spawn(
      _imageWorkerMain,
      readyPort.sendPort,
      debugName: 'PanoramaImageWorker',
    );


    final firstMessage =
    await readyPort.first;


    if (firstMessage is! SendPort) {
      readyPort.close();

      throw Exception(
        'Image worker başlatılamadı.',
      );
    }


    _sendPort =
        firstMessage;


    readyPort.close();
  }


  // ==========================================================================
  // RESİM HAZIRLA
  // ==========================================================================

  Future<Float32List> prepareImage(
      String imagePath,
      ) async {
    if (_sendPort == null) {
      throw Exception(
        'Image worker hazır değil.',
      );
    }


    final responsePort =
    ReceivePort();


    _sendPort!.send({
      'command': 'prepare',
      'path': imagePath,
      'replyPort':
      responsePort.sendPort,
    });


    final response =
    await responsePort.first;


    responsePort.close();


    if (response is! Map) {
      throw Exception(
        'Image worker geçersiz cevap gönderdi.',
      );
    }


    if (response['success'] != true) {
      throw Exception(
        response['error'] ??
            'Resim hazırlanamadı.',
      );
    }


    final transferable =
    response['data'];


    if (transferable
    is! TransferableTypedData) {
      throw Exception(
        'Worker tensor verisi hatalı.',
      );
    }


    final ByteBuffer buffer =
    transferable.materialize();


    final Uint8List bytes =
    buffer.asUint8List();


    return Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/
          Float32List.bytesPerElement,
    );
  }


  // ==========================================================================
  // WORKER KAPAT
  // ==========================================================================

  Future<void> dispose() async {
    try {
      _sendPort?.send({
        'command': 'close',
      });
    } catch (_) {}


    _sendPort = null;


    _isolate?.kill(
      priority:
      Isolate.immediate,
    );


    _isolate = null;
  }
}


// ============================================================================
// WORKER ENTRY POINT
//
// MUTLAKA CLASS DIŞINDA OLMALI.
// ============================================================================

void _imageWorkerMain(
    SendPort mainSendPort,
    ) async {
  final receivePort =
  ReceivePort();


  // Ana isolate'a worker'ın SendPort'unu gönder.
  mainSendPort.send(
    receivePort.sendPort,
  );


  await for (final message
  in receivePort) {

    if (message is! Map) {
      continue;
    }


    final command =
    message['command'];


    // ------------------------------------------------------------------------
    // CLOSE
    // ------------------------------------------------------------------------

    if (command == 'close') {
      receivePort.close();
      break;
    }


    // ------------------------------------------------------------------------
    // PREPARE
    // ------------------------------------------------------------------------

    if (command == 'prepare') {
      final path =
      message['path'] as String?;

      final replyPort =
      message['replyPort']
      as SendPort?;


      if (path == null ||
          replyPort == null) {
        continue;
      }


      try {
        final input =
        _prepareImageTensor(
          path,
        );


        // Float32 verisini kopyalamak yerine
        // transferable memory olarak gönder.
        final data =
        TransferableTypedData.fromList([
          input.buffer.asUint8List(
            input.offsetInBytes,
            input.lengthInBytes,
          ),
        ]);


        replyPort.send({
          'success': true,
          'data': data,
        });
      } catch (e, stackTrace) {
        replyPort.send({
          'success': false,
          'error': e.toString(),
          'stackTrace':
          stackTrace.toString(),
        });
      }
    }
  }
}


// ============================================================================
// BÜYÜK PANORAMAYI 224x224 MODEL TENSORUNA DÖNÜŞTÜR
//
// BU FONKSİYON BACKGROUND WORKER'DA ÇALIŞIR.
// ============================================================================

Float32List _prepareImageTensor(
    String imagePath,
    ) {
  // --------------------------------------------------------------------------
  // 1. DOSYAYI OKU
  // --------------------------------------------------------------------------

  final bytes =
  File(imagePath)
      .readAsBytesSync();


  // --------------------------------------------------------------------------
  // 2. JPEG / PNG DECODE
  // --------------------------------------------------------------------------

  img.Image? image =
  img.decodeImage(bytes);


  if (image == null) {
    throw Exception(
      'Resim decode edilemedi: '
          '$imagePath',
    );
  }


  // --------------------------------------------------------------------------
  // 3. 224 x 224
  //
  // Python:
  // cv2.resize(img_rgb, (224,224))
  // --------------------------------------------------------------------------

  final resized =
  img.copyResize(
    image,
    width: 224,
    height: 224,
    interpolation:
    img.Interpolation.linear,
  );


  // Büyük resim referansını bırak.
  image = null;


  // --------------------------------------------------------------------------
  // 4. FLOAT32 RGB
  //
  // Model:
  // [1,224,224,3]
  //
  // Python testinde preprocess_input sonrası:
  //
  // min = 0
  // max = 255
  //
  // Dolayısıyla NORMALIZATION YOK.
  // --------------------------------------------------------------------------

  final input =
  Float32List(
    224 * 224 * 3,
  );


  int index = 0;


  for (int y = 0;
  y < 224;
  y++) {

    for (int x = 0;
    x < 224;
    x++) {

      final pixel =
      resized.getPixel(
        x,
        y,
      );


      input[index++] =
          pixel.r.toDouble();

      input[index++] =
          pixel.g.toDouble();

      input[index++] =
          pixel.b.toDouble();
    }
  }


  return input;
}

// ======================================================================
// BU FONKSİYON CLASS DIŞINDA OLACAK
// ======================================================================
//
// Büyük panorama:
//
// 8192 x 4096
//      ↓
// isolate içinde decode
//      ↓
// 224 x 224 resize
//      ↓
// RGB Float32
//      ↓
// ana isolate'a yalnızca küçük tensor döner
//
// ======================================================================

Float32List _prepareImageForModel(
    String imagePath,
    ) {
  // ----------------------------------------------------------
  // Dosyayı worker isolate içinde oku
  // ----------------------------------------------------------

  final Uint8List bytes =
  File(imagePath).readAsBytesSync();

  // ----------------------------------------------------------
  // JPEG / PNG decode
  // ----------------------------------------------------------

  img.Image? image =
  img.decodeImage(bytes);

  if (image == null) {
    throw Exception(
      'Resim decode edilemedi: $imagePath',
    );
  }

  // ----------------------------------------------------------
  // 224 x 224
  //
  // Python:
  //
  // cv2.resize(img_rgb, (224,224))
  //
  // ----------------------------------------------------------

  final img.Image resized =
  img.copyResize(
    image,
    width: 224,
    height: 224,
    interpolation: img.Interpolation.linear,
  );

  // Büyük resmi artık kullanmıyoruz
  image = null;

  // ----------------------------------------------------------
  // FLOAT32 TENSOR
  //
  // Model:
  // [1,224,224,3]
  //
  // Python tarafında:
  //
  // min = 0
  // max = 255
  //
  // Bu nedenle normalization YOK.
  // ----------------------------------------------------------

  final Float32List input =
  Float32List(
    224 * 224 * 3,
  );

  int index = 0;

  for (int y = 0; y < 224; y++) {
    for (int x = 0; x < 224; x++) {
      final pixel =
      resized.getPixel(x, y);

      input[index++] =
          pixel.r.toDouble();

      input[index++] =
          pixel.g.toDouble();

      input[index++] =
          pixel.b.toDouble();
    }
  }

  return input;
}

class HouseCreatorScreen extends StatefulWidget {
  final PanoramaData? initialHouse;
  final int? houseIndex;

  const HouseCreatorScreen({super.key, this.initialHouse, this.houseIndex});

  @override
  State<HouseCreatorScreen> createState() => _HouseCreatorScreenState();
}

const double kControlHeight = 40.0;
const double kControlFontSize = 16.0;

class _HouseCreatorScreenState extends State<HouseCreatorScreen> {
  final AIClassifier _aiClassifier = AIClassifier();

  static const String _kBatchConnectionPairId = 'batch_auto';
  final List<FloorEditor> _floors = (() {
    final floor = FloorEditor();
    floor.rooms.add(EditableRoom());
    return [floor];
  })();
  final TextEditingController _titleCtrl = TextEditingController(
    text: 'My House',
  );
  final TextEditingController _addressCtrl = TextEditingController(text: '');
  final TextEditingController _areaCtrl = TextEditingController(text: '');
  String _houseThumbPath = '';
  final List<bool> _floorExpanded = [false];

  late String _initialDigest;
  bool get _hasChanges => _computeDigest() != _initialDigest;

  late _HouseSnapshot _snapshot;
  bool _saving = false;

// TOPLU YÜKLEME İLERLEME BİLGİLERİ
  bool _batchUploading = false;
  int _batchCurrent = 0;
  int _batchTotal = 0;
  String _batchFileName = '';

  PanoramaData? _draftHouse;
  int? _createdHouseIndex;

  bool _showReorderIndicators = false;

  final Map<FloorEditor, int> _originalFloorOrder = {};

  final Map<FloorEditor, Map<EditableRoom, int>> _originalRoomOrder = {};

  void _captureOriginalFloorOrder() {
    _originalFloorOrder
      ..clear()
      ..addEntries(_floors.asMap().entries.map(
            (e) => MapEntry(e.value, e.key),
      ));
  }

  void _captureOriginalRoomOrder(FloorEditor floor) {
    if (_originalRoomOrder.containsKey(floor)) return;
    _originalRoomOrder[floor] = {
      for (final e in floor.rooms.asMap().entries) e.value: e.key,
    };
  }

  void _addFloor() {
    final index = _floors.length;
    final newFloor = FloorEditor();
    newFloor.rooms.add(EditableRoom());

    setState(() {
      _floors.add(newFloor);
      _floorExpanded.insert(index, false);

      if (_showReorderIndicators) {
        _originalFloorOrder[newFloor] = index;
      } else {
        _captureOriginalFloorOrder();
      }
    });
  }

  void _removeFloor(int floorIdx) {
    if (_floors.length == 1) return;

    final floorToRemove = _floors[floorIdx];

    setState(() {
      _floors.removeAt(floorIdx);
      if (floorIdx >= 0 && floorIdx < _floorExpanded.length) {
        _floorExpanded.removeAt(floorIdx);
      }

      _floorExpanded
        ..clear()
        ..addAll(List<bool>.filled(_floors.length, false));

      _showReorderIndicators = false;
      _captureOriginalFloorOrder();
      _originalRoomOrder.remove(floorToRemove);
    });
  }

  void _addRoom(int floorIdx) {
    _floors[floorIdx].rooms.add(EditableRoom());
    if (floorIdx >= 0 && floorIdx < _floorExpanded.length) {
      _floorExpanded[floorIdx] = true;
    }
    setState(() {});
    _syncStore();
  }

  void _deleteRoom(int floorIdx, int roomIdx) {
    final floor = _floors[floorIdx];

    if (floor.rooms.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keep at least one room on each floor')),
      );
      return;
    }

    if (floor.rooms.isEmpty) return;
    floor.rooms.removeAt(roomIdx);
    for (final r in floor.rooms) {
      r.connectedRoomIds = r.connectedRoomIds
          .where((id) => id != roomIdx)
          .map((id) => id > roomIdx ? id - 1 : id)
          .toList();
    }
    floor.hotspots.removeWhere(
          (h) => h.fromRoomId == roomIdx || h.toRoomId == roomIdx,
    );
    for (final h in floor.hotspots) {
      if (h.fromRoomId > roomIdx) h.fromRoomId -= 1;
      if (h.toRoomId > roomIdx) h.toRoomId -= 1;
    }
    setState(() {});
    _syncStore();
  }

  @override
  void initState() {
    super.initState();
    _aiClassifier.loadModel();

    if (widget.initialHouse != null) {
      _loadFromPanoramaData(widget.initialHouse!);
    } else {
      final loaded = _loadFromPanoramaStoreIfAny();
      if (!loaded) {
        PanoramaData().replaceFromEditors(_floors);
      }
    }
    _initialDigest = _computeDigest();
    _snapshot = _HouseSnapshot.capture(
      _titleCtrl.text,
      _addressCtrl.text,
      _areaCtrl.text,
      _houseThumbPath,
      _floors,
    );
    _captureOriginalFloorOrder();
  }

  @override
  void dispose() {
    _aiClassifier.dispose();
    super.dispose();
  }

  void _loadFromPanoramaData(PanoramaData data) {
    _titleCtrl.text = data.houseName;
    _addressCtrl.text = data.houseAddress;
    _areaCtrl.text = data.houseArea;
    _houseThumbPath = data.houseThumbnail;

    final floorKeys = data.floorRooms.keys.toList()..sort();
    final rebuilt = <FloorEditor>[];

    for (final fIdx in floorKeys) {
      final roomsData = data.floorRooms[fIdx] ?? const <RoomData>[];
      final hotspotsData = data.floorHotspots[fIdx] ?? const <HotspotData>[];

      final floor = FloorEditor();

      for (final rd in roomsData) {
        final r = EditableRoom();
        r.name = rd.name;
        r.imagePath = rd.imagePath;
        r.iconName = _iconNameFromIcon(rd.icon, fallback: 'circle_outlined');
        r.description = rd.description;
        r.connectedRoomIds = List<int>.from(rd.connectedRoomIds);
        r.presetId = rd.presetId;

        try {
          r.nameCtrl.text = r.name;
          r.imageCtrl.text = r.imagePath;
          r.descCtrl.text = r.description;
        } catch (_) {}
        floor.rooms.add(r);
      }

      for (final hd in hotspotsData) {
        floor.hotspots.add(
          EditableHotspot(
            fromRoomId: hd.fromRoomId,
            toRoomId: hd.toRoomId,
            latitude: hd.latitude,
            longitude: hd.longitude,
            text: hd.text,
            iconName: _iconNameFromIcon(hd.icon, fallback: 'arrow_forward'),
            changeFloor: hd.targetFloorId != null,
            targetFloorId: hd.targetFloorId,
          ),
        );
      }

      rebuilt.add(floor);
    }

    setState(() {
      _floors
        ..clear()
        ..addAll(rebuilt);
      _floorExpanded
        ..clear()
        ..addAll(List<bool>.filled(_floors.length, false));
    });
  }

  String _computeDigest() {
    final data = {
      'title': _titleCtrl.text.trim(),
      'address': _addressCtrl.text.trim(),
      'area': _areaCtrl.text.trim(),
      'thumb': _houseThumbPath,
      'floorsCount': _floors.length,
      'rooms': _floors
          .map(
            (f) => f.rooms
            .map((r) => '${r.name}|${r.iconName}|${r.imagePath}')
            .toList(),
      )
          .toList(),
    };
    return data.toString();
  }

  Future<void> _onExitPressed() async {
    if (_hasChanges && !_validateFields()) {
      return;
    }
    if (!_hasChanges) {
      Navigator.of(context).pop();
      return;
    }
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppStyles.cardRadius),
          side: BorderSide(
            color: AppStyles.border,
            width: AppStyles.borderWidth,
          ),
        ),
        title: Text(
          'Exit editor',
          style: TextStyle(
            color: AppStyles.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Do you want to save changes before exiting?',
          style: TextStyle(color: AppStyles.textSecondary),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          Row(
            children: [
              const Spacer(),
              _WhiteButton.icon(
                icon: Icons.logout,
                label: 'Discard & exit',
                onPressed: () => Navigator.of(ctx).pop('discard'),
              ),
              const SizedBox(width: 8),
              _WhiteButton.icon(
                icon: Icons.check,
                label: 'Save & exit',
                onPressed: () => Navigator.of(ctx).pop('save'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              _WhiteButton.icon(
                icon: Icons.close,
                label: 'Cancel',
                onPressed: () => Navigator.of(ctx).pop('cancel'),
              ),
            ],
          ),
        ],
      ),
    );
    switch (action) {
      case 'save':
        await _onSavePressed(exitAfter: true);
        break;
      case 'discard':
        setState(() {
          _snapshot.restoreInto(
            _titleCtrl,
            _addressCtrl,
            _areaCtrl,
                (v) => _houseThumbPath = v,
            _floors,
          );
          _floorExpanded
            ..clear()
            ..addAll(List<bool>.filled(_floors.length, false));
        });

        _syncStore();
        if (!mounted) return;
        Navigator.of(context).pop();
        break;
      default:
        break;
    }
  }

  Future<void> _onSavePressed({bool exitAfter = false}) async {
    if (_saving) return;
    if (_hasChanges && !_validateFields()) return;
    setState(() => _saving = true);
    try {
      await Future.delayed(const Duration(milliseconds: 300));
      _syncStore();
      final store = HousesStore.instance;
      if (widget.houseIndex == null) {
        if (_createdHouseIndex == null) {
          if (_draftHouse == null) {
            _draftHouse = PanoramaData()
              ..replaceFromEditors(
                _floors,
                name: _titleCtrl.text,
                address: _addressCtrl.text,
                area: _areaCtrl.text,
                thumbnail: _houseThumbPath,
              );
          }
          store.addHouse(_draftHouse!);
          _createdHouseIndex = store.houses.length - 1;
          store.selectedIndex = _createdHouseIndex!;
        } else {
          store.notifyListeners();
        }
      }
      _initialDigest = _computeDigest();
      _snapshot = _HouseSnapshot.capture(
        _titleCtrl.text,
        _addressCtrl.text,
        _areaCtrl.text,
        _houseThumbPath,
        _floors,
      );

      _showReorderIndicators = false;
      _captureOriginalFloorOrder();

      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('House saved')));
      if (exitAfter) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _loadFromPanoramaStoreIfAny() {
    final store = PanoramaData();
    if (store.floorRooms.isEmpty) return false;

    final floorKeys = store.floorRooms.keys.toList()..sort();
    final rebuilt = <FloorEditor>[];

    for (final fIdx in floorKeys) {
      final roomsData = store.floorRooms[fIdx] ?? const <RoomData>[];
      final hotspotsData = store.floorHotspots[fIdx] ?? const <HotspotData>[];

      final floor = FloorEditor();

      for (final rd in roomsData) {
        final r = EditableRoom();
        r.name = rd.name;
        r.imagePath = rd.imagePath;
        r.iconName = _iconNameFromIcon(rd.icon, fallback: 'circle_outlined');
        r.connectedRoomIds = List<int>.from(rd.connectedRoomIds);
        floor.rooms.add(r);
      }

      for (final hd in hotspotsData) {
        floor.hotspots.add(
          EditableHotspot(
            fromRoomId: hd.fromRoomId,
            toRoomId: hd.toRoomId,
            latitude: hd.latitude,
            longitude: hd.longitude,
            text: hd.text,
            iconName: _iconNameFromIcon(hd.icon, fallback: 'arrow_forward'),
            changeFloor: hd.targetFloorId != null,
            targetFloorId: hd.targetFloorId,
          ),
        );
      }

      rebuilt.add(floor);
    }

    setState(() {
      _floors
        ..clear()
        ..addAll(rebuilt);
      _floorExpanded
        ..clear()
        ..addAll(List<bool>.filled(_floors.length, false));
    });

    return true;
  }

  String _iconNameFromIcon(
      IconData icon, {
        String fallback = 'circle_outlined',
      }) {
    for (final entry in kIconCatalog.entries) {
      final v = entry.value;
      if (v.codePoint == icon.codePoint && v.fontFamily == icon.fontFamily) {
        return entry.key;
      }
    }
    return fallback;
  }

  void _syncStore() {
    final store = HousesStore.instance;

    if (widget.houseIndex != null &&
        widget.houseIndex! >= 0 &&
        widget.houseIndex! < store.houses.length) {
      final existing = store.houses[widget.houseIndex!];
      existing.replaceFromEditors(
        _floors,
        name: _titleCtrl.text,
        address: _addressCtrl.text,
        area: _areaCtrl.text,
        thumbnail: _houseThumbPath,
      );
      store.selectedIndex = widget.houseIndex!;
      store.notifyListeners();
      return;
    }

    if (_draftHouse == null) {
      _draftHouse = PanoramaData();
    }
    _draftHouse!.replaceFromEditors(
      _floors,
      name: _titleCtrl.text,
      address: _addressCtrl.text,
      area: _areaCtrl.text,
      thumbnail: _houseThumbPath,
    );

    if (_createdHouseIndex != null) {
      store.notifyListeners();
    }
  }

  bool _validateFields() {
    final name = _titleCtrl.text.trim();
    final address = _addressCtrl.text.trim();
    final area = _areaCtrl.text.trim();
    if (name.isEmpty || address.isEmpty || area.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please fill in all required fields: name, address, and area.',
          ),
        ),
      );
      return false;
    }
    if (double.tryParse(area) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Area must be a valid number.')),
      );
      return false;
    }
    return true;
  }

  @override
  @override
  Widget build(BuildContext context) {
    final base = ThemeData.light();

    final themed = base.copyWith(
      scaffoldBackgroundColor: AppStyles.surfaceMuted,

      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        foregroundColor: AppStyles.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 44,
        centerTitle: true,
        titleSpacing: 8,

        titleTextStyle: TextStyle(
          color: AppStyles.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),

        toolbarTextStyle: TextStyle(
          color: AppStyles.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),

        iconTheme: IconThemeData(
          color: AppStyles.textPrimary,
          size: 20,
        ),

        actionsIconTheme: IconThemeData(
          color: AppStyles.textPrimary,
          size: 20,
        ),

        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),

      textTheme: base.textTheme.apply(
        bodyColor: AppStyles.textPrimary,
        displayColor: AppStyles.textPrimary,
      ),

      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: TextStyle(
          color: AppStyles.textPrimary,
        ),

        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(
            AppStyles.surface,
          ),

          elevation: const WidgetStatePropertyAll(4),

          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                AppStyles.cardRadius,
              ),
            ),
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppStyles.surface,

        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),

        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(
            AppStyles.cardRadius,
          ),
          borderSide: BorderSide(
            color: AppStyles.border,
            width: AppStyles.borderWidth,
          ),
        ),

        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(
            AppStyles.cardRadius,
          ),
          borderSide: BorderSide(
            color: AppStyles.border,
            width: AppStyles.borderWidth,
          ),
        ),

        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(
            AppStyles.cardRadius,
          ),
          borderSide: BorderSide(
            color: AppStyles.textPrimary,
            width: 1.5,
          ),
        ),

        labelStyle: TextStyle(
          color: AppStyles.textSecondary,
        ),

        floatingLabelStyle: TextStyle(
          color: AppStyles.textPrimary,
          fontWeight: FontWeight.w600,
        ),

        hintStyle: TextStyle(
          color: AppStyles.textSecondary.withOpacity(0.5),
        ),

        prefixIconColor: AppStyles.textSecondary,
      ),

      chipTheme: base.chipTheme.copyWith(
        backgroundColor: AppStyles.surface,
        selectedColor: AppStyles.controlBgActive,

        side: BorderSide(
          color: AppStyles.border,
          width: AppStyles.borderWidth,
        ),

        labelStyle: TextStyle(
          color: AppStyles.textPrimary,
        ),

        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            AppStyles.cardRadius,
          ),

          side: BorderSide(
            color: AppStyles.border,
            width: AppStyles.borderWidth,
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppStyles.textPrimary,
          backgroundColor: AppStyles.surface,
          elevation: 0,

          side: BorderSide(
            color: AppStyles.border,
            width: AppStyles.borderWidth,
          ),

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              AppStyles.cardRadius,
            ),
          ),

          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: AppStyles.textPrimary,
          backgroundColor: AppStyles.surface,
          elevation: 0,

          side: BorderSide(
            color: AppStyles.border,
            width: AppStyles.borderWidth,
          ),

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              AppStyles.cardRadius,
            ),
          ),

          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
      ),
    );

    return Theme(
      data: themed,

      child: Scaffold(
        backgroundColor: AppStyles.surfaceMuted,

        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('House Creator'),
        ),

        // ==========================================
        // BODY
        // ==========================================
        body: Stack(
          children: [

            // ---------------------------------------
            // NORMAL HOUSE CREATOR EKRANI
            // ---------------------------------------
            CustomScrollView(
              slivers: [

                // HOUSE THUMBNAIL
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      12,
                      12,
                      12,
                      8,
                    ),

                    child: _ThumbnailBox(
                      path: _houseThumbPath,

                      onPick: (p) {
                        setState(() {
                          _houseThumbPath = p;
                        });
                      },
                    ),
                  ),
                ),

                // -----------------------------------
                // HOUSE INFORMATION
                // -----------------------------------
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      12,
                      12,
                      12,
                      0,
                    ),

                    child: Column(
                      children: [

                        TextField(
                          controller: _titleCtrl,

                          style: TextStyle(
                            color: AppStyles.textPrimary,
                            fontWeight: FontWeight.bold,
                          ),

                          decoration:
                          const InputDecoration(
                            labelText: 'House title *',
                            prefixIcon:
                            Icon(Icons.home_outlined),
                          ),
                        ),

                        const SizedBox(height: 12),

                        TextField(
                          controller: _addressCtrl,

                          style: TextStyle(
                            color: AppStyles.textPrimary,
                          ),

                          decoration:
                          const InputDecoration(
                            labelText: 'Address *',
                            prefixIcon:
                            Icon(Icons.location_on_outlined),
                          ),
                        ),

                        const SizedBox(height: 12),

                        TextField(
                          controller: _areaCtrl,

                          style: TextStyle(
                            color: AppStyles.textPrimary,
                          ),

                          keyboardType:
                          const TextInputType
                              .numberWithOptions(
                            decimal: true,
                          ),

                          inputFormatters: [
                            FilteringTextInputFormatter
                                .allow(
                              RegExp(r'^\d*\.?\d*'),
                            ),
                          ],

                          decoration:
                          const InputDecoration(
                            labelText: 'Area (m²) *',
                            prefixIcon:
                            Icon(Icons.aspect_ratio),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SliverToBoxAdapter(
                  child: SizedBox(height: 12),
                ),

                // -----------------------------------
                // FLOORS
                // -----------------------------------
                SliverToBoxAdapter(
                  child: AnimatedSize(
                    duration:
                    const Duration(milliseconds: 300),

                    curve: Curves.easeInOut,

                    alignment: Alignment.topCenter,

                    child: ReorderableListView(
                      shrinkWrap: true,

                      physics:
                      const NeverScrollableScrollPhysics(),

                      buildDefaultDragHandles: false,

                      proxyDecorator:
                          (child, index, animation) {
                        return child;
                      },

                      onReorder:
                          (oldIndex, newIndex) {
                        setState(() {
                          if (newIndex > oldIndex) {
                            newIndex -= 1;
                          }

                          if (!_showReorderIndicators) {
                            _captureOriginalFloorOrder();
                          }

                          final floor =
                          _floors.removeAt(
                            oldIndex,
                          );

                          _floors.insert(
                            newIndex,
                            floor,
                          );

                          final expanded =
                          _floorExpanded.removeAt(
                            oldIndex,
                          );

                          _floorExpanded.insert(
                            newIndex,
                            expanded,
                          );

                          _showReorderIndicators =
                          true;
                        });

                        _syncStore();
                      },

                      children: [
                        for (
                        int index = 0;
                        index < _floors.length;
                        index++
                        )
                          Container(
                            key: ObjectKey(
                              _floors[index],
                            ),

                            child: _buildFloorTile(
                              context,
                              _floors[index],
                              index,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                const SliverToBoxAdapter(
                  child: SizedBox(height: 72),
                ),
              ],
            ),

            // =======================================
            // TOPLU PANORAMA YÜKLEME EKRANI
            // =======================================
            if (_batchUploading)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withOpacity(0.40),

                  child: Center(
                    child: Container(
                      width: 310,

                      padding:
                      const EdgeInsets.all(24),

                      decoration: BoxDecoration(
                        color: Colors.white,

                        borderRadius:
                        BorderRadius.circular(18),

                        boxShadow: const [
                          BoxShadow(
                            blurRadius: 20,
                            offset: Offset(0, 8),
                            color: Color.fromRGBO(
                              0,
                              0,
                              0,
                              0.20,
                            ),
                          ),
                        ],
                      ),

                      child: Column(
                        mainAxisSize:
                        MainAxisSize.min,

                        children: [

                          // LOADING ICON
                          const SizedBox(
                            width: 42,
                            height: 42,

                            child:
                            CircularProgressIndicator(
                              strokeWidth: 4,
                            ),
                          ),

                          const SizedBox(height: 20),

                          // TITLE
                          Text(
                            'Loading panoramas',

                            textAlign:
                            TextAlign.center,

                            style: TextStyle(
                              fontSize: 17,

                              fontWeight:
                              FontWeight.w700,

                              color:
                              AppStyles.textPrimary,
                            ),
                          ),

                          const SizedBox(height: 8),

                          Text(
                            'Artificial intelligence determines the room type.',

                            textAlign:
                            TextAlign.center,

                            style: TextStyle(
                              fontSize: 12,

                              color:
                              AppStyles.textSecondary,
                            ),
                          ),

                          const SizedBox(height: 20),

                          // CURRENT / TOTAL
                          Text(
                            '$_batchCurrent / $_batchTotal',

                            style: TextStyle(
                              fontSize: 16,

                              fontWeight:
                              FontWeight.w700,

                              color:
                              AppStyles.textPrimary,
                            ),
                          ),

                          const SizedBox(height: 12),

                          // PROGRESS BAR
                          ClipRRect(
                            borderRadius:
                            BorderRadius.circular(10),

                            child:
                            LinearProgressIndicator(
                              minHeight: 8,

                              value:
                              _batchTotal <= 0
                                  ? 0
                                  : (_batchCurrent /
                                  _batchTotal)
                                  .clamp(
                                0.0,
                                1.0,
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // CURRENT FILE
                          Container(
                            width: double.infinity,

                            padding:
                            const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),

                            decoration: BoxDecoration(
                              color:
                              AppStyles.surfaceMuted,

                              borderRadius:
                              BorderRadius.circular(
                                10,
                              ),
                            ),

                            child: Text(
                              _batchFileName.isEmpty
                                  ? 'Preparing...'
                                  : _batchFileName,

                              textAlign:
                              TextAlign.center,

                              maxLines: 2,

                              overflow:
                              TextOverflow.ellipsis,

                              style: TextStyle(
                                fontSize: 12,

                                color: AppStyles
                                    .textSecondary,
                              ),
                            ),
                          ),

                          const SizedBox(height: 14),

                          Text(
                            'Please wait until the process is complete.',

                            textAlign:
                            TextAlign.center,

                            style: TextStyle(
                              fontSize: 11,

                              color: AppStyles
                                  .textSecondary
                                  .withOpacity(0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),

        // ==========================================
        // ALT MENÜ
        // ==========================================
        bottomNavigationBar: SafeArea(
          minimum:
          const EdgeInsets.fromLTRB(
            16,
            8,
            16,
            16,
          ),

          child: Column(
            mainAxisSize: MainAxisSize.min,

            children: [

              _WhiteButton.icon(
                icon: Icons.add,
                label: 'Add Floor',

                // Panorama yüklenirken butona basılmasın
                onPressed: _batchUploading
                    ? () {}
                    : _addFloor,
              ),

              const SizedBox(height: 10),

              Row(
                children: [

                  _WhiteButton.icon(
                    icon: Icons.delete_outline,
                    label: 'Delete house',

                    onPressed: _batchUploading
                        ? () {}
                        : () async {
                      final ok =
                      await confirmDeleteDialog(
                        context,

                        title:
                        'Delete house',

                        message:
                        'This will remove all floors, rooms, and connections.',

                        confirmLabel:
                        'Delete',

                        confirmIcon:
                        Icons.delete_outline,
                      );

                      if (!ok) return;

                      final store =
                          HousesStore.instance;

                      if (widget.houseIndex !=
                          null &&
                          widget.houseIndex! >=
                              0 &&
                          widget.houseIndex! <
                              store.houses
                                  .length) {

                        store.deleteHouse(
                          widget.houseIndex!,
                        );

                        if (!mounted) {
                          return;
                        }

                        Navigator.of(context)
                            .pop();
                      } else {

                        setState(() {
                          _floors.clear();

                          final floor =
                          FloorEditor();

                          floor.rooms.add(
                            EditableRoom(),
                          );

                          _floors.add(
                            floor,
                          );

                          _floorExpanded
                            ..clear()
                            ..addAll(
                              List<bool>.filled(
                                _floors.length,
                                false,
                              ),
                            );

                          _houseThumbPath =
                          '';

                          _titleCtrl.text =
                          'My House';

                          _addressCtrl.text =
                          '';

                          _areaCtrl.text = '';
                        });

                        _syncStore();
                      }
                    },
                  ),

                  const Spacer(),

                  _WhiteButton.icon(
                    icon: Icons.exit_to_app,
                    label: 'Exit',

                    onPressed: _batchUploading
                        ? () {}
                        : _onExitPressed,
                  ),

                  const SizedBox(width: 8),

                  if (_saving)

                    const SizedBox(
                      width: 40,
                      height: kControlHeight,

                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,

                          child:
                          CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                    )

                  else

                    _WhiteButton.icon(
                      icon: Icons.check,
                      label: 'Save',

                      isPrimary: true,

                      onPressed: _batchUploading
                          ? () {}
                          : () =>
                          _onSavePressed(),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openRoomEditor(int fIdx, int rIdx) async {
    _syncStore();

    final store = HousesStore.instance;
    PanoramaData panoramaDataToUse;
    if (widget.houseIndex != null) {
      panoramaDataToUse = store.houses[widget.houseIndex!];
    } else if (_draftHouse != null) {
      panoramaDataToUse = _draftHouse!;
    } else {
      panoramaDataToUse = PanoramaData()..replaceFromEditors(_floors);
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RoomEditorPage(
          floor: _floors[fIdx],
          roomIndex: rIdx,
          floorIndex: fIdx,
          panoramaData: panoramaDataToUse,
          allFloorsEditors: _floors,
        ),
      ),
    );
    setState(() {});
    _syncStore();
  }

  Future<bool> confirmDeleteDialog(
      BuildContext context, {
        required String title,
        required String message,
        String confirmLabel = 'Delete',
        String cancelLabel = 'Cancel',
        IconData confirmIcon = Icons.delete_outline,
      }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppStyles.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppStyles.cardRadius),
          side: BorderSide(
            color: AppStyles.border,
            width: AppStyles.borderWidth,
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: AppStyles.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          message,
          style: TextStyle(color: AppStyles.textSecondary),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          Row(
            children: [
              _WhiteButton.icon(
                icon: Icons.close,
                label: cancelLabel,
                onPressed: () => Navigator.of(ctx).pop(false),
              ),
              const Spacer(),
              _WhiteButton.icon(
                icon: confirmIcon,
                label: confirmLabel,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ],
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Widget _buildRoomCard(int fIdx, int rIdx, EditableRoom room) {
    final floor = _floors[fIdx];
    final connCount = floor.hotspots.where((h) => h.fromRoomId == rIdx).length;
    final bool canDeleteRoom = floor.rooms.length > 1;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppStyles.cardRadius),
        onTap: () => _openRoomEditor(fIdx, rIdx),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          decoration: BoxDecoration(
            color: AppStyles.surface,
            borderRadius: BorderRadius.circular(AppStyles.cardRadius),
            border: Border.all(
              color: AppStyles.border,
              width: AppStyles.borderWidth,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {},
                child: ReorderableDragStartListener(
                  index: rIdx,
                  child: SizedBox(
                    width: 36,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildRoomReorderIndicator(floor, room, rIdx),
                        const SizedBox(height: 4),
                        Icon(
                          Icons.drag_handle,
                          color: AppStyles.accentInactive,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _PanoPreviewBox(
                imagePath: room.imagePath,
                iconName: room.iconName,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            room.name.isEmpty ? 'Pano $rIdx' : room.name,
                            style: TextStyle(
                              color: AppStyles.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (room.isBatchUpload)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppStyles.surfaceAccent,
                              borderRadius: BorderRadius.circular(
                                AppStyles.pillRadius,
                              ),
                              border: Border.all(
                                color: AppStyles.border,
                                width: AppStyles.borderWidth,
                              ),
                            ),
                            child: Text(
                              'Batch',
                              style: TextStyle(
                                color: AppStyles.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$connCount connection${connCount == 1 ? '' : 's'}',
                      style: TextStyle(color: AppStyles.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  color: AppStyles.surfaceAccent,
                  borderRadius: BorderRadius.circular(AppStyles.pillRadius),
                ),
                child: IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    color: canDeleteRoom
                        ? AppStyles.textSecondary
                        : const Color.fromRGBO(0, 0, 0, 0.3),
                  ),
                  onPressed: canDeleteRoom
                      ? () async {
                    final ok = await confirmDeleteDialog(
                      context,
                      title: 'Delete pano',
                      message:
                      'This will remove this room and its connections.',
                    );
                    if (ok) _deleteRoom(fIdx, rIdx);
                  }
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReorderIndicator(FloorEditor floor, int currentIndex) {
    final int? orig = _originalFloorOrder[floor];
    if (!_showReorderIndicators || orig == null) {
      return const Icon(Icons.minimize, size: 18, color: Colors.black54);
    }

    final int delta = orig - currentIndex;
    if (delta == 0) {
      return const Icon(Icons.minimize, size: 18, color: Colors.black54);
    }

    final bool movedUp = delta > 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          movedUp ? Icons.arrow_upward : Icons.arrow_downward,
          size: 16,
          color: Colors.black54,
        ),
        Text(
          '${delta.abs()}',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Colors.black54,
          ),
        ),
      ],
    );
  }

  Widget _buildRoomReorderIndicator(
      FloorEditor floor, EditableRoom room, int currentIndex) {
    final origMap = _originalRoomOrder[floor];
    if (!_showReorderIndicators || origMap == null) {
      return const Icon(Icons.minimize, size: 16, color: Colors.black54);
    }
    final int? orig = origMap[room];
    if (orig == null) {
      return const Icon(Icons.minimize, size: 16, color: Colors.black54);
    }
    final int delta = orig - currentIndex;
    if (delta == 0) {
      return const Icon(Icons.minimize, size: 16, color: Colors.black54);
    }
    final bool movedUp = delta > 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          movedUp ? Icons.arrow_upward : Icons.arrow_downward,
          size: 16,
          color: Colors.black54,
        ),
        const SizedBox(width: 2),
        Text(
          '${delta.abs()}',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Colors.black54,
          ),
        ),
      ],
    );
  }

  Widget _buildFloorTile(
      BuildContext context,
      FloorEditor floor,
      int fIdx, {
        bool interactive = true,
      }) {
    final canDeleteFloor = interactive && _floors.length > 1;
    final isExpanded = (fIdx >= 0 && fIdx < _floorExpanded.length)
        ? _floorExpanded[fIdx]
        : false;

    final card = Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: AppStyles.surface,
        borderRadius: BorderRadius.circular(AppStyles.cardRadius),
        border: Border.all(
          color: AppStyles.border,
          width: AppStyles.borderWidth,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableDragStartListener(
            index: fIdx,
            child: SizedBox(
              width: 40,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16.0, 10.0, 0.0, 10.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildReorderIndicator(floor, fIdx),
                    const SizedBox(height: 4),
                    Icon(
                      Icons.drag_handle,
                      color: AppStyles.accentInactive,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: AppStyles.border,
                splashFactory: NoSplash.splashFactory,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                hoverColor: Colors.transparent,
                listTileTheme: const ListTileThemeData(
                  tileColor: Colors.transparent,
                  selectedTileColor: Colors.transparent,
                ),
              ),
              child: ExpansionTile(
                key: ObjectKey(floor),
                initiallyExpanded: isExpanded,
                onExpansionChanged: interactive
                    ? (open) => setState(() {
                  if (fIdx >= 0 && fIdx < _floorExpanded.length) {
                    _floorExpanded[fIdx] = open;
                  }
                })
                    : null,
                backgroundColor: Colors.transparent,
                collapsedBackgroundColor: Colors.transparent,
                shape: const RoundedRectangleBorder(
                  side: BorderSide(color: Colors.transparent),
                ),
                collapsedShape: const RoundedRectangleBorder(
                  side: BorderSide(color: Colors.transparent),
                ),
                title: Row(
                  children: [
                    Text(
                      'Floor $fIdx',
                      style: TextStyle(
                        color: AppStyles.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                subtitle: Text(
                  '${floor.rooms.length} panoramas • ${floor.hotspots.length} connections',
                  style: TextStyle(color: AppStyles.textSecondary),
                ),
                trailing: Container(
                  decoration: BoxDecoration(
                    color: AppStyles.surfaceAccent,
                    borderRadius: BorderRadius.circular(AppStyles.pillRadius),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Add pano',
                        icon: Icon(
                          Icons.meeting_room,
                          color: AppStyles.textSecondary,
                        ),
                        onPressed: interactive ? () => _addRoom(fIdx) : null,
                      ),
                      IconButton(
                        tooltip: canDeleteFloor
                            ? 'Delete Floor'
                            : 'Keep at least one floor',
                        icon: Icon(
                          Icons.delete_outline,
                          color: canDeleteFloor
                              ? AppStyles.textSecondary
                              : const Color.fromRGBO(0, 0, 0, 0.3),
                        ),
                        onPressed: canDeleteFloor
                            ? () async {
                          final ok = await confirmDeleteDialog(
                            context,
                            title: 'Delete floor',
                            message:
                            'This will remove Floor $fIdx and all its rooms and connections.',
                          );
                          if (ok) _removeFloor(fIdx);
                        }
                            : null,
                      ),
                    ],
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(1.0, 8.0, 24.0, 8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _WhiteButton.icon(
                              icon: Icons.upload_file,
                              label: 'Batch upload panoramas',
                                onPressed: () async {
                                  final result = await FilePicker.platform.pickFiles(
                                    type: FileType.image,
                                    allowMultiple: true,
                                  );

                                  final files = result?.files ?? const <PlatformFile>[];

                                  if (files.isEmpty) return;

                                  // Dosyaları alfabetik sırala
                                  files.sort((a, b) {
                                    final an = a.name.toLowerCase();
                                    final bn = b.name.toLowerCase();
                                    return an.compareTo(bn);
                                  });

                                  // Eğer sadece varsayılan boş oda varsa kaldır
                                  setState(() {
                                    if (floor.rooms.length == 1 &&
                                        _isDefaultRoom(floor.rooms.first)) {
                                      floor.rooms.removeAt(0);
                                      floor.hotspots.clear();
                                    }

                                    _batchUploading = true;
                                    _batchCurrent = 0;
                                    _batchTotal = files.length;
                                    _batchFileName = '';
                                  });

                                  final startIndex = floor.rooms.length;

                                  try {
                                    for (int i = 0; i < files.length; i++) {
                                      final f = files[i];

                                      final path = f.path;

                                      if (path == null || path.isEmpty) {
                                        continue;
                                      }

                                      if (!mounted) return;

                                      setState(() {
                                        _batchCurrent = i + 1;
                                        _batchFileName = f.name;
                                      });

                                      // Oda nesnesi oluştur
                                      final room = EditableRoom();

                                      room.isBatchUpload = true;
                                      room.imagePath = path;
                                      room.imageCtrl.text = path;

                                      String predictedName = 'backyard';

                                      // AI sınıflandırması
                                      try {
                                        predictedName =
                                        await _aiClassifier.classifyImage(path);
                                      } catch (e) {
                                        debugPrint(
                                          "AI Tahmin hatası: $e",
                                        );
                                      }

                                      room.name = predictedName;
                                      room.nameCtrl.text = predictedName;

                                      if (!mounted) return;

                                      // Odayı listeye ekle
                                      setState(() {
                                        floor.rooms.add(room);
                                      });

                                      // UI'nın yeniden çizilmesine fırsat ver
                                      await Future<void>.delayed(
                                        Duration.zero,
                                      );
                                    }

                                    if (!mounted) return;

                                    // Yeni yüklenen odalar arasındaki bağlantıları oluştur
                                    setState(() {
                                      final lastNew = floor.rooms.length - 1;
                                      final firstNew = startIndex;

                                      if (firstNew <= lastNew) {
                                        // Önceden oda varsa ilk yeni odayı önceki odaya bağla
                                        if (firstNew > 0) {
                                          final prev = firstNew - 1;

                                          _ensureBidirectionalConnection(
                                            floor,
                                            prev,
                                            firstNew,
                                          );
                                        }

                                        // Toplu yüklenen odaları sırayla birbirine bağla
                                        for (int r = firstNew; r < lastNew; r++) {
                                          _ensureBidirectionalConnection(
                                            floor,
                                            r,
                                            r + 1,
                                            pairId: _kBatchConnectionPairId,
                                          );
                                        }
                                      }

                                      // Katı açık tut
                                      if (fIdx >= 0 &&
                                          fIdx < _floorExpanded.length) {
                                        _floorExpanded[fIdx] = true;
                                      }
                                    });

                                    // Store'u güncelle
                                    _syncStore();
                                  } catch (e, stackTrace) {
                                    debugPrint(
                                      "Toplu panorama yükleme hatası: $e",
                                    );

                                    debugPrint(
                                      "$stackTrace",
                                    );

                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Panorama yüklenirken hata oluştu: $e',
                                          ),
                                        ),
                                      );
                                    }
                                  } finally {
                                    if (mounted) {
                                      setState(() {
                                        _batchUploading = false;
                                        _batchCurrent = 0;
                                        _batchTotal = 0;
                                        _batchFileName = '';
                                      });
                                    }
                                  }
                                },
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Panoramas',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppStyles.textPrimary,
                          ),
                        ),
                        floor.rooms.isEmpty
                            ? Padding(
                          padding:
                          const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'No rooms yet. Add one with the button above.',
                            style: TextStyle(
                              color: AppStyles.textSecondary,
                            ),
                          ),
                        )
                            : ReorderableListView(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: false,
                          proxyDecorator: (child, index, animation) =>
                          child,
                          onReorder: (oldIndex, newIndex) {
                            setState(() {
                              if (newIndex > oldIndex) newIndex -= 1;

                              _captureOriginalRoomOrder(floor);
                              _showReorderIndicators = true;

                              final moved =
                              floor.rooms.removeAt(oldIndex);
                              floor.rooms.insert(newIndex, moved);

                              _remapRoomIndicesForFloor(
                                  floor, oldIndex, newIndex);
                              _remapConnectedRoomIdsForFloor(
                                  floor, oldIndex, newIndex);

                              _rebuildBatchConnections(floor);
                            });
                            _syncStore();
                          },
                          children: [
                            for (int rIdx = 0;
                            rIdx < floor.rooms.length;
                            rIdx++)
                              Container(
                                key: ObjectKey(floor.rooms[rIdx]),
                                margin: const EdgeInsets.symmetric(
                                    vertical: 6),
                                child: _buildRoomCard(
                                    fIdx, rIdx, floor.rooms[rIdx]),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: card,
    );
  }

  bool _hasHotspot(FloorEditor floor, int from, int to) {
    return floor.hotspots.any(
          (h) => !h.changeFloor && h.fromRoomId == from && h.toRoomId == to,
    );
  }

  bool _isDefaultRoom(EditableRoom room) {
    return room.imagePath.isEmpty &&
        (room.name.isEmpty || room.name.startsWith('Pano ')) &&
        room.iconName == 'circle_outlined' &&
        room.description.isEmpty &&
        room.presetId == -1 &&
        room.connectedRoomIds.isEmpty;
  }

  void _ensureConnection(
      FloorEditor floor,
      int from,
      int to, {
        double latitude = 0.0,
        double longitude = 25.0,
        String text = '',
        String iconName = 'arrow_forward',
        String? pairId,
      }) {
    if (_hasHotspot(floor, from, to)) return;
    floor.hotspots.add(
      EditableHotspot(
        fromRoomId: from,
        toRoomId: to,
        latitude: latitude,
        longitude: longitude,
        text: text,
        iconName: iconName,
        pairId: pairId,
      ),
    );
  }

  void _ensureBidirectionalConnection(
      FloorEditor floor,
      int a,
      int b, {
        String? pairId,
      }) {
    _ensureConnection(
      floor,
      a,
      b,
      longitude: 25.0,
      iconName: 'arrow_forward',
      pairId: pairId,
    );
    _ensureConnection(
      floor,
      b,
      a,
      longitude: -25.0,
      iconName: 'arrow_back',
      pairId: pairId,
    );

    if (!floor.rooms[a].connectedRoomIds.contains(b)) {
      floor.rooms[a].connectedRoomIds.add(b);
    }
    if (!floor.rooms[b].connectedRoomIds.contains(a)) {
      floor.rooms[b].connectedRoomIds.add(a);
    }
  }

  void _rebuildBatchConnections(FloorEditor floor) {
    floor.hotspots.removeWhere(
          (h) => h.pairId == _kBatchConnectionPairId,
    );

    final batchIndices = <int>[];
    for (var i = 0; i < floor.rooms.length; i++) {
      if (floor.rooms[i].isBatchUpload) {
        batchIndices.add(i);
      }
    }

    if (batchIndices.length > 1) {
      for (var i = 0; i < batchIndices.length - 1; i++) {
        _ensureBidirectionalConnection(
          floor,
          batchIndices[i],
          batchIndices[i + 1],
          pairId: _kBatchConnectionPairId,
        );
      }
    }

    _rebuildConnectedRoomIdsFromHotspots(floor);
  }

  void _rebuildConnectedRoomIdsFromHotspots(FloorEditor floor) {
    for (final room in floor.rooms) {
      room.connectedRoomIds = [];
    }

    for (var rIdx = 0; rIdx < floor.rooms.length; rIdx++) {
      final conns = floor.hotspots
          .where((h) => h.fromRoomId == rIdx && !(h.changeFloor == true))
          .map((h) => h.toRoomId)
          .where((to) => to >= 0 && to < floor.rooms.length)
          .toSet()
          .toList()
        ..sort();
      floor.rooms[rIdx].connectedRoomIds = conns;
    }
  }

  void _remapRoomIndicesForFloor(
      FloorEditor floor, int oldIndex, int newIndex) {
    for (final h in floor.hotspots) {
      if (h.fromRoomId == oldIndex) {
        h.fromRoomId = newIndex;
      } else if (oldIndex < newIndex) {
        if (h.fromRoomId > oldIndex && h.fromRoomId <= newIndex) {
          h.fromRoomId -= 1;
        }
      } else if (oldIndex > newIndex) {
        if (h.fromRoomId >= newIndex && h.fromRoomId < oldIndex) {
          h.fromRoomId += 1;
        }
      }

      if (h.toRoomId == oldIndex) {
        h.toRoomId = newIndex;
      } else if (oldIndex < newIndex) {
        if (h.toRoomId > oldIndex && h.toRoomId <= newIndex) {
          h.toRoomId -= 1;
        }
      } else if (oldIndex > newIndex) {
        if (h.toRoomId >= newIndex && h.toRoomId < oldIndex) {
          h.toRoomId += 1;
        }
      }
    }
  }

  void _remapConnectedRoomIdsForFloor(
      FloorEditor floor, int oldIndex, int newIndex) {
    for (final r in floor.rooms) {
      r.connectedRoomIds = r.connectedRoomIds.map((id) {
        if (id == oldIndex) return newIndex;
        if (oldIndex < newIndex) {
          if (id > oldIndex && id <= newIndex) return id - 1;
        } else if (oldIndex > newIndex) {
          if (id >= newIndex && id < oldIndex) return id + 1;
        }
        return id;
      }).toList();
    }
  }
}

class _PanoPreviewBox extends StatelessWidget {
  final String imagePath;
  final String iconName;
  const _PanoPreviewBox({
    required this.imagePath,
    required this.iconName,
  });

  bool get _hasImage => imagePath.isNotEmpty && File(imagePath).existsSync();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _hasImage
          ? () => showDialog(
        context: context,
        builder: (_) => _ImagePreviewDialog(imagePath: imagePath),
      )
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppStyles.cardRadius),
        child: SizedBox(
          width: 56,
          height: 56,
          child: Stack(
            children: [
              Positioned.fill(
                child: _hasImage
                    ? Image.file(
                  File(imagePath),
                  fit: BoxFit.cover,
                )
                    : Container(
                  color: AppStyles.accentInactive.withOpacity(0.2),
                  child: Icon(
                    Icons.panorama,
                    color: AppStyles.textSecondary,
                    size: 24,
                  ),
                ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: const Color.fromRGBO(255, 255, 255, 0.85),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    kIconCatalog[iconName] ?? Icons.circle_outlined,
                    color: AppStyles.textPrimary,
                    size: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImagePreviewDialog extends StatelessWidget {
  final String imagePath;
  const _ImagePreviewDialog({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Stack(
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppStyles.cardRadius),
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(
                  File(imagePath),
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color.fromRGBO(255, 255, 255, 0.9),
                  borderRadius: BorderRadius.circular(AppStyles.cardRadius),
                  border: Border.all(
                    color: AppStyles.border,
                    width: AppStyles.borderWidth,
                  ),
                ),
                child: Icon(
                  Icons.close,
                  size: 20,
                  color: AppStyles.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThumbnailBox extends StatelessWidget {
  final String path;
  final ValueChanged<String> onPick;
  const _ThumbnailBox({required this.path, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: InkWell(
        onTap: () async {
          final result = await FilePicker.platform.pickFiles(
            type: FileType.image,
            allowMultiple: false,
          );
          final p = result?.files.single.path;
          if (p != null) {
            onPick(p);
          }
        },
        borderRadius: BorderRadius.circular(AppStyles.cardRadius),
        child: Container(
          decoration: BoxDecoration(
            color: AppStyles.surface,
            borderRadius: BorderRadius.circular(AppStyles.cardRadius),
            border: Border.all(
              color: AppStyles.border,
              width: AppStyles.borderWidth,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(
                child: (path.isNotEmpty && File(path).existsSync())
                    ? Image.file(File(path), fit: BoxFit.cover)
                    : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.panorama,
                        color: AppStyles.textSecondary,
                        size: 28,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Upload Thumbnail',
                        style: TextStyle(color: AppStyles.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color.fromRGBO(255, 255, 255, 0.9),
                    borderRadius: BorderRadius.circular(AppStyles.cardRadius),
                    border: Border.all(
                      color: AppStyles.border,
                      width: AppStyles.borderWidth,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.image_search,
                          size: 16,
                          color: AppStyles.textPrimary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Change image',
                          style: TextStyle(color: AppStyles.textPrimary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WhiteButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool isPrimary;

  const _WhiteButton.icon({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isPrimary = false,
  });

  @override
  State<_WhiteButton> createState() => _WhiteButtonState();
}

class _WhiteButtonState extends State<_WhiteButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.isPrimary ? AppStyles.textPrimary : AppStyles.surface;
    final fg = widget.isPrimary ? AppStyles.surface : AppStyles.textPrimary;
    final border = Border.all(
      color: widget.isPrimary ? AppStyles.textPrimary : AppStyles.border,
      width: AppStyles.borderWidth,
    );
    final radius = BorderRadius.circular(AppStyles.cardRadius);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _pressed ? bg.withOpacity(0.95) : bg,
            borderRadius: radius,
            border: border,
            boxShadow: widget.isPrimary && _hover
                ? [
              BoxShadow(
                color: AppStyles.textPrimary.withOpacity(0.2),
                blurRadius: 8,
                offset: const Offset(0, 4),
              )
            ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 16, color: fg),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: TextStyle(color: fg, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HouseSnapshot {
  final String title;
  final String address;
  final String area;
  final String thumb;
  final List<FloorEditor> floors;

  _HouseSnapshot({
    required this.title,
    required this.address,
    required this.area,
    required this.thumb,
    required this.floors,
  });

  static _HouseSnapshot capture(
      String title,
      String address,
      String area,
      String thumb,
      List<FloorEditor> floors,
      ) {
    final copiedFloors = floors.map((f) => f.deepCopy()).toList();
    return _HouseSnapshot(
      title: title,
      address: address,
      area: area,
      thumb: thumb,
      floors: copiedFloors,
    );
  }

  void restoreInto(
      TextEditingController titleCtrl,
      TextEditingController addressCtrl,
      TextEditingController areaCtrl,
      ValueChanged<String> setThumb,
      List<FloorEditor> targetFloors,
      ) {
    titleCtrl.text = title;
    addressCtrl.text = address;
    areaCtrl.text = area;
    setThumb(thumb);
    targetFloors
      ..clear()
      ..addAll(floors.map((f) => f.deepCopy()).toList());
  }
}

extension DeepCopyFloorEditor on FloorEditor {
  FloorEditor deepCopy() {
    final copy = FloorEditor();
    copy.rooms.addAll(rooms.map((r) => r.deepCopy()));
    copy.hotspots.addAll(hotspots.map((h) => h.deepCopy()));
    return copy;
  }
}

extension DeepCopyEditableRoom on EditableRoom {
  EditableRoom deepCopy() {
    final copy = EditableRoom();
    copy.name = name;
    copy.iconName = iconName;
    copy.imagePath = imagePath;
    copy.description = description;
    copy.isBatchUpload = isBatchUpload;
    copy.connectedRoomIds = List<int>.from(connectedRoomIds);
    return copy;
  }
}

extension DeepCopyEditableHotspot on EditableHotspot {
  EditableHotspot deepCopy() {
    return EditableHotspot(
      fromRoomId: fromRoomId,
      toRoomId: toRoomId,
      latitude: latitude,
      longitude: longitude,
      text: text,
      iconName: iconName,
      pairId: pairId,
      isPaired: isPaired,
      changeFloor: changeFloor,
      targetFloorId: targetFloorId,
    );
  }
}