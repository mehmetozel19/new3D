import 'dart:async';

import 'package:flutter/material.dart';
import 'package:panorama_viewer/panorama_viewer.dart';

// ============================================================================
// PANORAMA ENGINE  (Matterport tarzı geçiş sürümü)
//
// GEÇİŞ AKIŞI (halkaya dokununca):
//   1. Kamera, gidilecek yöne doğru yumuşakça döner      (~450 ms)
//   2. Hedef resim hazır değilse kısa bir yükleme gösterilir
//   3. "Süzülme": eski oda ileri doğru yakınlaşırken (dolly-zoom),
//      yeni oda aynı yönde, hafif yakından başlayıp üstüne yumuşakça açılır
//   4. Yeni oda aynı bakış yönünde devam eder (yön korunur)
//
// ZEMİN HALKALARI:
//   Oklar yerine zemine yatık, yarı saydam halkalar (Matterport gibi).
//
// HIZ / KALİTE:
//   dragBoost, maxTextureWidth, imageCacheMb, precache (önceki sürümle aynı)
// ============================================================================

class PanoramaEngine extends StatefulWidget {
  const PanoramaEngine({
    super.key,
    required this.panoImages,
    this.initialPanoId = 0,
    this.hotspots = const [],
    this.onPanoChanged,
    this.onViewChanged,
    this.onHotspotClicked,
    this.onCameraDriving,
    this.borderRadius = 16.0,
    this.animSpeed = 0,
    this.sensitivity = 1.0,
    this.dragBoost = 3.0,
    this.maxTextureWidth = 6144,
    this.imageCacheMb = 600,
    this.maxZoom = 5.0,
    this.editMode = false,
    this.onEditSave,
    this.onEditCancel,
    this.ringPositions = const {},
    this.sensorControl = SensorControl.orientation,
    this.transitionDuration = const Duration(milliseconds: 1200),
  });

  final List<Image> panoImages;
  final int initialPanoId;
  final List<PanoHotspot> hotspots;

  final Function(int panoId)? onPanoChanged;

  final Function(double lon, double lat, double zoom)? onViewChanged;

  final Function(PanoHotspot hotspot)? onHotspotClicked;

  final void Function(bool active)? onCameraDriving;

  final double borderRadius;
  final double animSpeed;

  /// Efektif hassasiyet = sensitivity * dragBoost
  final double sensitivity;
  final double dragBoost;

  /// Texture genişlik sınırı (px). Zayıf cihazlarda 4096 kullan.
  final int maxTextureWidth;

  /// Flutter ImageCache üst sınırı (MB).
  final int imageCacheMb;

  final double maxZoom;

  /// true iken halkaya dokunup seçersin, sonra panoramada yeni yere dokunursun.
  final bool editMode;

  /// Düzenleme modunda "Kaydet"e basılınca tüm halka konumlarıyla çağrılır.
  final void Function(Map<String, List<double>> rings)? onEditSave;

  /// Düzenleme modunda "İptal"e basılınca çağrılır.
  final VoidCallback? onEditCancel;

  /// Kayıtlı halka konumları. Anahtar: "from>to", değer: [boylam, enlem].
  final Map<String, List<double>> ringPositions;

  final SensorControl sensorControl;

  /// Süzülme (dolly) süresi. İçeride 600-1000 ms aralığına sıkıştırılır.
  final Duration transitionDuration;

  @override
  State<PanoramaEngine> createState() => PanoramaEngineState();
}

// ============================================================================
// PANORAMA ENGINE STATE
// ============================================================================

class PanoramaEngineState extends State<PanoramaEngine>
    with TickerProviderStateMixin {
  // --------------------------------------------------------------------------
  // AYARLAR (gerekirse buradan ince ayar yap)
  // --------------------------------------------------------------------------

  /// Halkaların zemindeki dikey konumu. Daha aşağı = daha negatif.
  static const double _floorLat = -32.0;

  /// Geçişte kameranın bakacağı eğim.
  static const double _travelLat = -10.0;

  /// İLERİ ve GERİ halkaların yatay yönü (derece, -180..180).
  /// Resimlerin gidiş ekseni ortadan değil yandan geçiyorsa buradan ayarla.
  /// Örnek: ileri sola çıkıyorsa -90, geri sağa çıkıyorsa 90.
  /// İleri/geri yer değiştirmiş görünürse iki değerin işaretini değiştir.
  static const double _forwardLon = -90.0;
  static const double _backLon = 90.0;

  /// Yön döndürme süresi.
  static const Duration _turnDuration = Duration(milliseconds: 450);

  late PanoramaController _panoramaController;

  late int _panoId;

  List<Image> _images = const [];

  final List<int> _navigationHistory = [];

  bool _isTransitioning = false;
  bool _isBusy = false; // dönme + yükleme + süzülme boyunca true
  bool _isLoading = false;
  bool _lockFocusCancel = false; // geçiş sırasında dışarıdan iptali engelle

  double _lon = 0;
  double _lat = 0;
  double _zoom = 1.0;

  Image? _fromImage;
  Image? _toImage;

  double? _savedLongitude;
  double? _savedLatitude;
  double? _savedZoom;

  int? _pendingTargetPanoId;

  AnimationController? _lookCtrl;
  Completer<void>? _lookCompleter;

  bool _programmaticDriving = false;

  List<Hotspot>? _hotspotCache;

  // Halka konumları: "from>to" -> [boylam, enlem]
  final Map<String, List<double>> _ring = {};
  int? _hotspotCachePano;
  int? _hotspotCacheCount;

  double get _effectiveSensitivity => widget.sensitivity * widget.dragBoost;

  // ==========================================================================
  // INIT
  // ==========================================================================

  @override
  void initState() {
    super.initState();

    _ensureImageCache();

    _loadRings();

    _images = _wrapImages(widget.panoImages);

    _panoId = _images.isEmpty
        ? 0
        : widget.initialPanoId.clamp(0, _images.length - 1);

    _panoramaController = PanoramaController();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _precacheNeighbors();
    });
  }

  // ==========================================================================
  // IMAGE CACHE + RESIZE
  // ==========================================================================

  void _ensureImageCache() {
    final cache = PaintingBinding.instance.imageCache;
    final wanted = widget.imageCacheMb * 1024 * 1024;
    if (cache.maximumSizeBytes < wanted) {
      cache.maximumSizeBytes = wanted;
    }
  }

  List<Image> _wrapImages(List<Image> source) {
    return source.map((img) {
      final provider = img.image;

      final ImageProvider effective = provider is ResizeImage
          ? provider
          : ResizeImage(
              provider,
              width: widget.maxTextureWidth,
              allowUpscaling: false,
            );

      return Image(
        image: effective,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
      );
    }).toList();
  }

  bool _sameProviders(List<Image> a, List<Image> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].image != b[i].image) return false;
    }
    return true;
  }

  // ==========================================================================
  // PRECACHE
  // ==========================================================================

  void _precacheNeighbors() {
    if (!mounted || _images.isEmpty) return;

    for (final i in [_panoId - 1, _panoId + 1]) {
      if (i >= 0 && i < _images.length) {
        precacheImage(_images[i].image, context).catchError((_) {});
      }
    }
  }

  // ==========================================================================
  // WIDGET UPDATE
  // ==========================================================================

  @override
  void didUpdateWidget(covariant PanoramaEngine oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.editMode != widget.editMode) {
      // Düzenleme açılırken/kapanırken kayıtlı konumlara dön.
      _loadRings();
      _hotspotCache = null;
    } else if (!widget.editMode &&
        !_sameRingMaps(oldWidget.ringPositions, widget.ringPositions)) {
      _loadRings();
      _hotspotCache = null;
    }

    final bool changed =
        !_sameProviders(oldWidget.panoImages, widget.panoImages) ||
            oldWidget.maxTextureWidth != widget.maxTextureWidth;

    if (!changed) return;

    _images = _wrapImages(widget.panoImages);
    _hotspotCache = null;

    if (_isTransitioning || _isBusy) return;
    if (_images.isEmpty) return;

    final int desired = widget.initialPanoId.clamp(0, _images.length - 1);

    setState(() {
      _navigationHistory.clear();
      _panoId = desired;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _precacheNeighbors();
    });
  }

  // ==========================================================================
  // PROGRAMMATIC CAMERA
  // ==========================================================================

  void _setProgrammaticDriving(bool active) {
    if (_programmaticDriving == active) return;

    _programmaticDriving = active;

    try {
      widget.onCameraDriving?.call(active);
    } catch (_) {}
  }

  // ==========================================================================
  // HISTORY
  // ==========================================================================

  void _addToHistory(int panoId) {
    if (_navigationHistory.isNotEmpty && _navigationHistory.last == panoId) {
      return;
    }
    _navigationHistory.add(panoId);
  }

  // ==========================================================================
  // SET CURRENT PANO
  // ==========================================================================

  bool setCurrentPano(
    int panoId, {
    bool saveHistory = true,
  }) {
    if (_isTransitioning || _isBusy) return false;
    if (_images.isEmpty) return false;

    final int id = panoId.clamp(0, _images.length - 1);

    if (id == _panoId) return true;

    setState(() {
      if (saveHistory) {
        _addToHistory(_panoId);
      }
      _panoId = id;
      _hotspotCache = null;
    });

    widget.onPanoChanged?.call(_panoId);
    _precacheNeighbors();

    return true;
  }

  // ==========================================================================
  // DISPOSE
  // ==========================================================================

  @override
  void dispose() {
    _lockFocusCancel = false;
    _cancelLookInternal();
    _panoramaController.dispose();
    super.dispose();
  }

  // ==========================================================================
  // VIEW CHANGED
  // ==========================================================================

  void _onViewChanged(double longitude, double latitude, double tilt) {
    _lon = longitude;
    _lat = latitude;
    _zoom = _panoramaController.getZoom();

    widget.onViewChanged?.call(_lon, _lat, _zoom);
  }

  // ==========================================================================
  // YÖN: hedef sonraki resimse 0°, önceki resimse 180°
  // ==========================================================================

  double _directionLon(int targetPanoId) => _ringPos(_panoId, targetPanoId)[0];

  // ==========================================================================
  // HALKA KONUMLARI
  // ==========================================================================

  String _ringKey(int from, int to) => '$from>$to';

  void _loadRings() {
    _ring.clear();
    widget.ringPositions.forEach((k, v) {
      if (v.length >= 2) _ring[k] = [v[0], v[1]];
    });
  }

  List<double> _ringPos(int from, int to) {
    final p = _ring[_ringKey(from, to)];
    if (p != null) return p;
    return [to > from ? _forwardLon : _backLon, _floorLat];
  }

  bool _sameRingMaps(
    Map<String, List<double>> a,
    Map<String, List<double>> b,
  ) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final o = b[e.key];
      if (o == null || o.length != e.value.length) return false;
      for (int i = 0; i < o.length; i++) {
        if (o[i] != e.value[i]) return false;
      }
    }
    return true;
  }

  // Artının (ekran ortası) gösterdiği yere halkayı koy.
  void _placeRing(int target) {
    final String key = _ringKey(_panoId, target);

    final double lon = _normalizeLon(_panoramaController.getLongitude());
    final double lat =
        _panoramaController.getLatitude().clamp(-90.0, 90.0).toDouble();

    setState(() {
      _ring[key] = [lon, lat];
      _hotspotCache = null;
    });

    debugPrint(
      'RING $key lon=${lon.toStringAsFixed(1)} lat=${lat.toStringAsFixed(1)}',
    );
  }

  void _handleEditSave() {
    final copy = <String, List<double>>{
      for (final e in _ring.entries) e.key: [e.value[0], e.value[1]],
    };
    widget.onEditSave?.call(copy);
  }

  // ==========================================================================
  // NAVIGATE TO (pusula vb. dışarıdan çağrılır)
  // ==========================================================================

  bool navigateTo(int targetPanoId) {
    if (_isTransitioning || _isBusy) return false;
    if (targetPanoId == _panoId) return false;

    cancelFocus();

    final match = widget.hotspots.firstWhere(
      (h) => h.panoId == _panoId && h.targetPanoId == targetPanoId,
      orElse: () => const PanoHotspot(
        panoId: -1,
        targetPanoId: -1,
        latitude: 0,
        longitude: 0,
      ),
    );

    if (match.panoId == -1) return false;

    _goToHotspotPano(match.targetPanoId, match);

    return true;
  }

  // ==========================================================================
  // MATTERPORT TARZI GEÇİŞ
  // ==========================================================================

  Future<void> _goToHotspotPano(int nextPanoId, PanoHotspot hotspot) async {
    if (_isTransitioning || _isBusy) return;
    if (nextPanoId < 0 || nextPanoId >= _images.length) return;

    _isBusy = true;
    _lockFocusCancel = false; // başlangıçta parent'ın temizlemesine izin ver

    _setProgrammaticDriving(true);

    // Parent burada UI'yı sadeleştirir (cancelFocus çağırabilir).
    widget.onHotspotClicked?.call(hotspot);

    // Bundan sonra dışarıdan gelen cancelFocus çağrıları yok sayılır.
    _lockFocusCancel = true;

    try {
      // Hedef resmi arka planda yüklemeye başla (dönme sırasında).
      bool loaded = false;
      final Future<void> preload =
          precacheImage(_images[nextPanoId].image, context)
              .timeout(const Duration(seconds: 8))
              .catchError((_) {})
              .then((_) => loaded = true);

      // 1) Gidilecek yöne dön.
      await _animateLookTo(
        _directionLon(nextPanoId),
        _travelLat,
        duration: _turnDuration,
        curve: Curves.easeInOutCubic,
      );

      if (!mounted) return;
      _setProgrammaticDriving(true);

      // 2) Resim hazır değilse kısa süre sonra yükleme göster.
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted && _isBusy && !loaded) {
          setState(() => _isLoading = true);
        }
      });

      await preload;

      if (!mounted) return;

      final double lon = _panoramaController.getLongitude();
      final double lat = _panoramaController.getLatitude();
      final double zoom = _panoramaController.getZoom();

      // 3) Süzülme geçişini başlat.
      setState(() {
        _isLoading = false;
        _isTransitioning = true;

        _fromImage = _images[_panoId];
        _toImage = _images[nextPanoId];

        _savedLongitude = lon;
        _savedLatitude = lat;
        _savedZoom = zoom;

        _pendingTargetPanoId = nextPanoId;
      });
    } catch (_) {
      if (mounted) _resetTransitionState();
    }
  }

  // ==========================================================================
  // GEÇİŞ TAMAMLANDI
  // ==========================================================================

  Future<void> _finishPanoTransition() async {
    final int? target = _pendingTargetPanoId;

    if (target == null) {
      _resetTransitionState();
      return;
    }

    final double arriveLon = _savedLongitude ?? 0.0;
    final double arriveLat = _savedLatitude ?? _travelLat;

    setState(() {
      _addToHistory(_panoId);
      _panoId = target;
      _pendingTargetPanoId = null;
      _hotspotCache = null;
    });

    widget.onPanoChanged?.call(_panoId);

    // Yeni odada bakış yönü, gidiş yönüyle aynı kalsın.
    void keepHeading() {
      try {
        _panoramaController.setView(arriveLat, arriveLon);
      } catch (_) {}
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => keepHeading());

    // Ana viewer yeni texture'ı yüklerken geçiş katmanı kısa süre daha
    // ekranda kalsın; böylece geçişin sonunda göz kırpma/titreme olmaz.
    await Future<void>.delayed(const Duration(milliseconds: 260));

    if (!mounted) return;

    keepHeading();
    _resetTransitionState();
    _precacheNeighbors();
  }

  void _resetTransitionState() {
    _lockFocusCancel = false;

    setState(() {
      _isTransitioning = false;
      _isBusy = false;
      _isLoading = false;

      _fromImage = null;
      _toImage = null;

      _savedLongitude = null;
      _savedLatitude = null;
      _savedZoom = null;

      _pendingTargetPanoId = null;
    });

    _setProgrammaticDriving(false);
  }

  // ==========================================================================
  // HOTSPOTS (zemin halkaları, cache'li)
  // ==========================================================================

  List<Hotspot> _buildHotspots() {
    if (_images.isEmpty) return const [];

    if (_hotspotCache != null &&
        _hotspotCachePano == _panoId &&
        _hotspotCacheCount == _images.length) {
      return _hotspotCache!;
    }

    final List<Hotspot> result = [];

    void addRing(int target) {
      final pos = _ringPos(_panoId, target);
      final PanoHotspot hotspot = PanoHotspot(
        panoId: _panoId,
        targetPanoId: target,
        latitude: pos[1],
        longitude: pos[0],
      );

      result.add(
        Hotspot(
          latitude: pos[1],
          longitude: pos[0],
          width: 84,
          height: 84,
          widget: _floorRing(
            label: target > _panoId ? 'İLERİ' : 'GERİ',
            onPressed: () {
              if (widget.editMode) return;
              _goToHotspotPano(target, hotspot);
            },
          ),
        ),
      );
    }

    if (_panoId > 0) addRing(_panoId - 1);
    if (_panoId < _images.length - 1) addRing(_panoId + 1);

    _hotspotCachePano = _panoId;
    _hotspotCacheCount = _images.length;
    _hotspotCache = result;

    return result;
  }

  /// Zemine yatık, yarı saydam halka (Matterport benzeri).
  Widget _floorRing({
    required String label,
    required VoidCallback onPressed,
  }) {
    const Color ringColor = Color(0xE6FFFFFF);
    const Color fillColor = Color(0x40FFFFFF);

    return RepaintBoundary(
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 84,
          height: 84,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Dikeyde ezerek zemine yatmış görüntü ver.
              Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(1.0, 0.5, 1.0),
                child: Container(
                  width: 70,
                  height: 70,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fillColor,
                    border: Border.all(color: ringColor, width: 3),
                  ),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ringColor,
                    ),
                  ),
                ),
              ),
              if (widget.editMode)
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // DÜZENLEME PANELİ (artı işareti + butonlar)
  // ==========================================================================

  List<Widget> _buildEditOverlay() {
    final bool hasPrev = _panoId > 0;
    final bool hasNext = _panoId < _images.length - 1;

    Widget btn(String text, VoidCallback? onTap, {bool primary = false}) {
      return ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: primary ? const Color(0xFFFFA726) : Colors.white,
          foregroundColor: Colors.black87,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          minimumSize: const Size(0, 34),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        child: Text(text),
      );
    }

    return [
      // Artı işareti (ekran ortası)
      const Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: Icon(
              Icons.add,
              size: 42,
              color: Colors.white,
              shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
            ),
          ),
        ),
      ),

      // Üst panel
      Positioned(
        top: 10,
        left: 10,
        right: 10,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 10, 10),
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.chevron_left,
                      color: hasPrev ? Colors.white : Colors.white24,
                    ),
                    onPressed: hasPrev
                        ? () => setCurrentPano(_panoId - 1, saveHistory: false)
                        : null,
                  ),
                  Text(
                    'Oda ${_panoId + 1} / ${_images.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.chevron_right,
                      color: hasNext ? Colors.white : Colors.white24,
                    ),
                    onPressed: hasNext
                        ? () => setCurrentPano(_panoId + 1, saveHistory: false)
                        : null,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: widget.onEditCancel,
                    child: const Text(
                      'İptal',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                  const SizedBox(width: 4),
                  btn('Kaydet', _handleEditSave, primary: true),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Artıyı kapının önündeki zemine getir, sonra butona bas',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 11.5),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (hasNext)
                    btn('İleri halkayı buraya koy',
                        () => _placeRing(_panoId + 1)),
                  if (hasPrev)
                    btn('Geri halkayı buraya koy',
                        () => _placeRing(_panoId - 1)),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }

  // ==========================================================================
  // ÇİFT TIK = ZOOM
  // ==========================================================================

  void _handleDoubleTap() {
    if (_isTransitioning || _isBusy) return;

    final double currentZoom = _panoramaController.getZoom();
    final double targetZoom = currentZoom >= 2.0 ? 1.0 : currentZoom + 0.5;

    _panoramaController.setZoom(targetZoom);
  }

  // ==========================================================================
  // HOTSPOT'A BAK (pusula önizlemesi)
  // ==========================================================================

  bool focusHotspotTo(
    int targetPanoId, {
    Duration duration = const Duration(milliseconds: 0),
  }) {
    if (_isTransitioning || _isBusy) return false;

    final match = widget.hotspots.firstWhere(
      (h) => h.panoId == _panoId && h.targetPanoId == targetPanoId,
      orElse: () => const PanoHotspot(
        panoId: -1,
        targetPanoId: -1,
        latitude: 0,
        longitude: 0,
      ),
    );

    if (match.panoId == -1) return false;

    _setProgrammaticDriving(true);

    _animateLookTo(
      _directionLon(targetPanoId),
      _travelLat,
      duration: duration,
    );

    return true;
  }

  // ==========================================================================
  // FOCUS İPTAL
  // ==========================================================================

  void cancelFocus() {
    // Geçiş sürerken parent'ın görünüm değişimi tepkileri animasyonu bozmasın.
    if (_lockFocusCancel) return;
    _cancelLookInternal();
  }

  void _cancelLookInternal() {
    final ctrl = _lookCtrl;
    _lookCtrl = null;

    ctrl?.stop();
    ctrl?.dispose();

    final c = _lookCompleter;
    _lookCompleter = null;
    if (c != null && !c.isCompleted) c.complete();

    _setProgrammaticDriving(false);
  }

  // ==========================================================================
  // KAMERAYI BELİRLİ YÖNE ÇEVİR (tamamlanınca biter)
  // ==========================================================================

  Future<void> _animateLookTo(
    double targetLon,
    double targetLat, {
    Duration duration = const Duration(milliseconds: 0),
    Curve curve = Curves.easeOutCubic,
  }) {
    _cancelLookInternal();

    final completer = Completer<void>();
    _lookCompleter = completer;

    final startLon = _panoramaController.getLongitude();
    final startLat = _panoramaController.getLatitude();

    final normStartLon = _normalizeLon(startLon);
    final normTargetLon = _normalizeLon(targetLon);

    final deltaLon = _shortestDeltaDegrees(normStartLon, normTargetLon);
    final deltaLat = targetLat - startLat;

    _setProgrammaticDriving(true);

    final ctrl = AnimationController(vsync: this, duration: duration);
    _lookCtrl = ctrl;

    ctrl.addListener(() {
      final t = curve.transform(ctrl.value);

      final lon = _normalizeLon(normStartLon + deltaLon * t);
      final lat = (startLat + deltaLat * t).clamp(-90.0, 90.0);

      try {
        _panoramaController.setView(lat, lon);
      } catch (_) {}
    });

    ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        if (identical(_lookCtrl, ctrl)) {
          _cancelLookInternal();
        }
      }
    });

    ctrl.forward();

    return completer.future;
  }

  // ==========================================================================
  // YARDIMCILAR
  // ==========================================================================

  double _normalizeLon(double lon) {
    var l = lon;
    while (l > 180) {
      l -= 360;
    }
    while (l < -180) {
      l += 360;
    }
    return l;
  }

  double _shortestDeltaDegrees(double from, double to) {
    var d = to - from;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return d;
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    if (_images.isEmpty) {
      return const Center(
        child: Text('Panorama bulunamadı'),
      );
    }

    final int dollyMs =
        widget.transitionDuration.inMilliseconds.clamp(600, 1000);

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      clipBehavior: Clip.hardEdge,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: _handleDoubleTap,
        child: Stack(
          children: [
            // ================================================================
            // PANORAMA
            // ================================================================
            PanoramaViewer(
              panoramaController: _panoramaController,
              animSpeed: widget.animSpeed,
              sensitivity: _effectiveSensitivity,
              maxZoom: widget.maxZoom,
              sensorControl: SensorControl.none,
              onViewChanged: _onViewChanged,
              hotspots: _buildHotspots(),
              child: _images[_panoId],
            ),

            // ================================================================
            // YÜKLEME (sadece resim geç gelirse)
            // ================================================================
            if (widget.editMode) ..._buildEditOverlay(),

            if (_isLoading)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black38,
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                ),
              ),

            // ================================================================
            // SÜZÜLME GEÇİŞİ
            // ================================================================
            if (_isTransitioning && _fromImage != null && _toImage != null)
              Positioned.fill(
                child: PanoramaTransition(
                  fromImage: _fromImage!,
                  toImage: _toImage!,
                  savedLongitude: _savedLongitude!,
                  savedLatitude: _savedLatitude!,
                  savedZoom: _savedZoom!,
                  maxZoom: widget.maxZoom,
                  borderRadius: widget.borderRadius,
                  transitionDuration: Duration(milliseconds: dollyMs),
                  onViewChanged: _onViewChanged,
                  onCompleted: _finishPanoTransition,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// PANO HOTSPOT
// ============================================================================

class PanoHotspot {
  final int panoId;
  final int targetPanoId;

  final double latitude;
  final double longitude;

  final double width;
  final double height;

  final String? text;
  final IconData? icon;
  final Widget? widget;

  final int? targetFloorId;

  const PanoHotspot({
    required this.panoId,
    required this.targetPanoId,
    required this.latitude,
    required this.longitude,
    this.width = 76,
    this.height = 76,
    this.text,
    this.icon,
    this.widget,
    this.targetFloorId,
  });

  bool get isCrossFloor => targetFloorId != null;
}

// ============================================================================
// PANORAMA TRANSITION  (süzülme / dolly-zoom + çapraz geçiş)
//
//  - Eski oda: yakınlaşır (zoom artar) -> ileri hareket hissi
//  - Yeni oda: hafif yakından başlar, normal zoom'a oturur, üstüne yumuşakça açılır
//  - Her iki viewer aynı yöne bakar -> yön korunur
// ============================================================================

class PanoramaTransition extends StatefulWidget {
  final Image fromImage;
  final Image toImage;

  final double savedLongitude;
  final double savedLatitude;
  final double savedZoom;
  final double maxZoom;

  final VoidCallback onCompleted;

  final Function(double lon, double lat, double zoom)? onViewChanged;

  final double borderRadius;

  final Duration transitionDuration;

  const PanoramaTransition({
    required this.fromImage,
    required this.toImage,
    required this.savedLongitude,
    required this.savedLatitude,
    required this.savedZoom,
    required this.onCompleted,
    this.maxZoom = 5.0,
    this.onViewChanged,
    this.borderRadius = 16.0,
    this.transitionDuration = const Duration(milliseconds: 900),
    super.key,
  });

  @override
  State<PanoramaTransition> createState() => _PanoramaTransitionState();
}

class _PanoramaTransitionState extends State<PanoramaTransition>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _toOpacity;

  late PanoramaController _fromController;
  late PanoramaController _toController;

  late double _z0;
  late double _fromEndZoom;
  late double _toStartZoom;

  @override
  void initState() {
    super.initState();

    _z0 = widget.savedZoom;
    _fromEndZoom = (_z0 * 2.2).clamp(1.0, widget.maxZoom);
    _toStartZoom = (_z0 * 1.6).clamp(1.0, widget.maxZoom);

    _fromController = PanoramaController();
    _toController = PanoramaController();

    _ctrl = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
    );

    _toOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.30, 0.90, curve: Curves.easeInOut),
    );

    _ctrl.addListener(_onTick);

    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onCompleted();
      }
    });

    _ctrl.forward();
  }

  void _onTick() {
    final t = _ctrl.value;

    final double fromZoom = _z0 +
        (_fromEndZoom - _z0) * Curves.easeInOutCubic.transform(t);

    final double toZoom = _toStartZoom +
        (_z0 - _toStartZoom) * Curves.easeOutCubic.transform(t);

    try {
      _fromController.setZoom(fromZoom);
      _toController.setZoom(toZoom);
    } catch (_) {}
  }

  void _onTransitionViewChanged(
    double longitude,
    double latitude,
    double tilt,
  ) {
    final zoom = _fromController.getZoom();

    widget.onViewChanged?.call(longitude, latitude, zoom);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          // ESKİ ODA (altta, tam opak)
          Positioned.fill(
            child: PanoramaViewer(
              panoramaController: _fromController,
              sensitivity: 0,
              animSpeed: 0,
              sensorControl: SensorControl.none,
              longitude: widget.savedLongitude,
              latitude: widget.savedLatitude,
              zoom: widget.savedZoom,
              maxZoom: widget.maxZoom,
              onViewChanged: _onTransitionViewChanged,
              child: widget.fromImage,
            ),
          ),

          // YENİ ODA (üstte, yumuşakça açılır)
          Positioned.fill(
            child: FadeTransition(
              opacity: _toOpacity,
              child: PanoramaViewer(
                panoramaController: _toController,
                sensitivity: 0,
                animSpeed: 0,
                sensorControl: SensorControl.none,
                longitude: widget.savedLongitude,
                latitude: widget.savedLatitude,
                zoom: _toStartZoom,
                maxZoom: widget.maxZoom,
                child: widget.toImage,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTick);
    _fromController.dispose();
    _toController.dispose();
    _ctrl.dispose();
    super.dispose();
  }
}
