import 'package:flutter/material.dart';
import 'package:panorama_viewer/panorama_viewer.dart';
import 'dart:math' as math;

// ============================================================================
// PANORAMA ENGINE
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
    this.sensorControl = SensorControl.orientation,
    this.transitionDuration = const Duration(milliseconds: 1200),
  });

  final List<Image> panoImages;
  final int initialPanoId;
  final List<PanoHotspot> hotspots;

  final Function(int panoId)? onPanoChanged;

  final Function(
      double lon,
      double lat,
      double zoom,
      )? onViewChanged;

  final Function(PanoHotspot hotspot)? onHotspotClicked;

  final void Function(bool active)? onCameraDriving;

  final double borderRadius;
  final double animSpeed;
  final double sensitivity;
  final SensorControl sensorControl;
  final Duration transitionDuration;

  @override
  State<PanoramaEngine> createState() => PanoramaEngineState();
}

// ============================================================================
// PANORAMA ENGINE STATE
// ============================================================================

class PanoramaEngineState extends State<PanoramaEngine>
    with TickerProviderStateMixin {
  late PanoramaController _panoramaController;

  late int _panoId;

  // --------------------------------------------------------------------------
  // GERİ GEÇMİŞİ
  // --------------------------------------------------------------------------

  final List<int> _navigationHistory = [];

  bool _isTransitioning = false;
  bool _isLoading = false;

  double _lon = 0;
  double _lat = 0;
  double _zoom = 1.0;

  Image? _fromImage;
  Image? _toImage;

  double? _savedLongitude;
  double? _savedLatitude;
  double? _savedZoom;

  double? _hotspotLon;
  double? _hotspotLat;

  // Hotspot animasyonu tamamlanınca hangi panoramaya geçileceğini saklar.
  int? _pendingTargetPanoId;

  AnimationController? _lookCtrl;

  bool _programmaticDriving = false;

  // ==========================================================================
  // INIT
  // ==========================================================================

  @override
  void initState() {
    super.initState();

    if (widget.panoImages.isEmpty) {
      _panoId = 0;
    } else {
      _panoId = widget.initialPanoId.clamp(
        0,
        widget.panoImages.length - 1,
      );
    }

    _panoramaController = PanoramaController();
  }

  // ==========================================================================
  // WIDGET UPDATE
  // ==========================================================================

  @override
  void didUpdateWidget(covariant PanoramaEngine oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (_isTransitioning) return;
    if (widget.panoImages.isEmpty) return;

    bool imagesReallyChanged =
        oldWidget.panoImages.length != widget.panoImages.length;

    if (!imagesReallyChanged) {
      for (int i = 0; i < widget.panoImages.length; i++) {
        final oldProvider = oldWidget.panoImages[i].image.toString();
        final newProvider = widget.panoImages[i].image.toString();

        if (oldProvider != newProvider) {
          imagesReallyChanged = true;
          break;
        }
      }
    }

    // Aynı panorama listesinde parent yalnızca initialPanoId'yi güncelledi diye
    // engine'i geri-ileri zıplatma. Engine aynı katta kendi navigasyonunu yönetir.
    if (!imagesReallyChanged) return;

    final int desired = widget.initialPanoId.clamp(
      0,
      widget.panoImages.length - 1,
    );

    setState(() {
      _navigationHistory.clear();
      _panoId = desired;
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
    if (_navigationHistory.isNotEmpty &&
        _navigationHistory.last == panoId) {
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
    if (_isTransitioning) {
      return false;
    }

    if (widget.panoImages.isEmpty) {
      return false;
    }

    final int id = panoId.clamp(
      0,
      widget.panoImages.length - 1,
    );

    if (id == _panoId) {
      return true;
    }

    setState(() {
      if (saveHistory) {
        _addToHistory(_panoId);
      }

      _panoId = id;
    });

    widget.onPanoChanged?.call(_panoId);

    return true;
  }

  // ==========================================================================
  // BACK
  // ==========================================================================

  void _goBack() {
    if (_isTransitioning) return;

    if (_navigationHistory.isEmpty) {
      return;
    }

    final int target = _navigationHistory.removeLast();

    setState(() {
      _panoId = target;
    });

    widget.onPanoChanged?.call(_panoId);
  }

  // ==========================================================================
  // DISPOSE
  // ==========================================================================

  @override
  void dispose() {
    _panoramaController.dispose();

    _lookCtrl?.dispose();

    _setProgrammaticDriving(false);

    super.dispose();
  }

  // ==========================================================================
  // VIEW CHANGED
  // ==========================================================================

  void _onViewChanged(
      double longitude,
      double latitude,
      double tilt,
      ) {
    _lon = longitude;
    _lat = latitude;
    _zoom = _panoramaController.getZoom();

    widget.onViewChanged?.call(
      _lon,
      _lat,
      _zoom,
    );
  }

  // ==========================================================================
  // NAVIGATE TO
  // ==========================================================================

  bool navigateTo(int targetPanoId) {
    if (_isTransitioning) return false;

    if (targetPanoId == _panoId) return false;

    cancelFocus();

    final match = widget.hotspots.firstWhere(
          (h) =>
      h.panoId == _panoId &&
          h.targetPanoId == targetPanoId,
      orElse: () => const PanoHotspot(
        panoId: -1,
        targetPanoId: -1,
        latitude: 0,
        longitude: 0,
      ),
    );

    if (match.panoId == -1) {
      return false;
    }

    _goToHotspotPano(
      match.targetPanoId,
      _autoHotspotLongitude(match),
      _autoHotspotLatitude(match),
      match,
    );

    return true;
  }

  // ==========================================================================
  // HOTSPOT İLE PANORAMA DEĞİŞTİR
  // ==========================================================================

  Future<void> _goToHotspotPano(
      int nextPanoId,
      double hotspotLon,
      double hotspotLat,
      PanoHotspot hotspot,
      ) async {
    if (_isTransitioning) return;

    if (nextPanoId < 0 ||
        nextPanoId >= widget.panoImages.length) {
      return;
    }

    _setProgrammaticDriving(true);

    widget.onHotspotClicked?.call(hotspot);

    final currentLon =
    _panoramaController.getLongitude();

    final currentLat =
    _panoramaController.getLatitude();

    final currentZoom =
    _panoramaController.getZoom();

    setState(() {
      _isLoading = true;
    });

    await Future.delayed(
      const Duration(milliseconds: 600),
    );

    if (!mounted) return;

    setState(() {
      _isLoading = false;

      _isTransitioning = true;

      _fromImage = widget.panoImages[_panoId];

      _toImage = widget.panoImages[nextPanoId];

      _savedLongitude = currentLon;
      _savedLatitude = currentLat;
      _savedZoom = currentZoom;

      _hotspotLon = hotspotLon;
      _hotspotLat = hotspotLat;

      _pendingTargetPanoId = nextPanoId;
    });
  }

  // ==========================================================================
  // HOTSPOT TRANSITION TAMAMLANDI
  // ==========================================================================

  void _finishPanoTransition() {
    final int? target = _pendingTargetPanoId;

    if (target == null) {
      _onTransitionCompleted();
      return;
    }

    setState(() {
      _addToHistory(_panoId);

      _panoId = target;

      _pendingTargetPanoId = null;
    });

    widget.onPanoChanged?.call(_panoId);

    _onTransitionCompleted();
  }

  // ==========================================================================
  // TRANSITION TEMİZLE
  // ==========================================================================

  void _onTransitionCompleted() {
    setState(() {
      _isTransitioning = false;

      _fromImage = null;
      _toImage = null;

      _savedLongitude = null;
      _savedLatitude = null;
      _savedZoom = null;

      _hotspotLon = null;
      _hotspotLat = null;

      _pendingTargetPanoId = null;
    });

    _setProgrammaticDriving(false);
  }

  // ==========================================================================
  // OTOMATİK STREET VIEW OK KONUMU
  //
  // Okların dikey konumu artık hotspot.latitude değerine bağlı değil.
  // Google Street View benzeri şekilde zemine yakın sabit bir bantta gösterilir.
  // Yatay yön için mevcut hotspot.longitude korunur; böylece hedef yön bozulmaz.
  // ==========================================================================

  double _autoHotspotLatitude(PanoHotspot hotspot) {
    // İleri/geri ok panoramanın dikey merkezinde görünür.
    return 0.0;
  }

  double _autoHotspotLongitude(PanoHotspot hotspot) {
    // İleri/geri ok panoramanın yatay merkezinde görünür.
    // Böylece eklenen her resimde ok başlangıçta tam karşıda çıkar.
    return 0.0;
  }

  // ==========================================================================
  // HOTSPOTS
  // ==========================================================================

  List<Hotspot> _buildHotspots() {
    final List<Hotspot> result = [];

    if (widget.panoImages.isEmpty) {
      return result;
    }

    // ------------------------------------------------------------
    // OTOMATİK SIRALI GEÇİŞ SİSTEMİ
    //
    // 1. resim  : sadece 2. resme ileri
    // Ara resim : bir önceki resme geri + bir sonraki resme ileri
    // Son resim : sadece bir önceki resme geri
    // ------------------------------------------------------------

    // GERİ OK
    if (_panoId > 0) {
      final PanoHotspot backHotspot = PanoHotspot(
        panoId: _panoId,
        targetPanoId: _panoId - 1,

        // Geri ok artık eski İLERİ okun bulunduğu konumda.
        latitude: -8,
        longitude: 0,
      );

      result.add(
        Hotspot(
          latitude: -28,
          longitude: 180,
          width: 76,
          height: 76,
          widget: _streetViewHotspotButton(
            hotspot: backHotspot,
            onPressed: () {
              _goToHotspotPano(
                _panoId - 1,
                0,
                -8,
                backHotspot,
              );
            },
          ),
        ),
      );
    }

    // İLERİ OK
    if (_panoId < widget.panoImages.length - 1) {
      final PanoHotspot forwardHotspot = PanoHotspot(
        panoId: _panoId,
        targetPanoId: _panoId + 1,

        // İleri ok artık eski GERİ okun bulunduğu konumda.
        // Panoramayı yaklaşık 180° çevirince görünür.
        latitude: -28,
        longitude: 180,
      );

      result.add(
        Hotspot(
          latitude: -8,
          longitude: 0,
          width: 76,
          height: 76,
          widget: _streetViewHotspotButton(
            hotspot: forwardHotspot,
            onPressed: () {
              _goToHotspotPano(
                _panoId + 1,
                180,
                -28,
                forwardHotspot,
              );
            },
          ),
        ),
      );
    }

    return result;
  }

  Widget _streetViewHotspotButton({
    required PanoHotspot hotspot,
    required VoidCallback onPressed,
  }) {
    final bool isBackTarget =
        hotspot.targetPanoId < _panoId;

    final IconData arrowIcon = isBackTarget
        ? Icons.keyboard_double_arrow_down_rounded
        : Icons.keyboard_double_arrow_up_rounded;

    return GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 76,
        height: 76,
        child: Center(
          child: Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.34),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withOpacity(0.78),
                width: 2.2,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, 0.42),
                  blurRadius: 18,
                  spreadRadius: 2,
                  offset: Offset(0, 5),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Kalınlık ve kontrast için koyu arka gölge.
                Transform.translate(
                  offset: const Offset(0, 2),
                  child: Icon(
                    arrowIcon,
                    size: 48,
                    color: Colors.black.withOpacity(0.55),
                  ),
                ),

                // Ana ok.
                Icon(
                  arrowIcon,
                  size: 48,
                  color: Colors.white,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // DEFAULT HOTSPOT BUTTON
  // ==========================================================================

  Widget _defaultHotspotButton({
    String? text,
    IconData? icon,
    VoidCallback? onPressed,
    PanoHotspot? hotspot,
  }) {
    final PanoHotspot effectiveHotspot = hotspot ??
        PanoHotspot(
          panoId: _panoId,
          targetPanoId: _panoId,
          latitude: 0,
          longitude: 0,
          text: text,
          icon: icon,
        );

    return _streetViewHotspotButton(
      hotspot: effectiveHotspot,
      onPressed: onPressed ?? () {},
    );
  }

  // ==========================================================================
  // TEK TIK = ZOOM
  // ==========================================================================

  void _handleSingleTap() {
    if (_isTransitioning) return;

    final double currentZoom =
    _panoramaController.getZoom();

    final double targetZoom =
    currentZoom >= 2.0
        ? 1.0
        : currentZoom + 0.5;

    _panoramaController.setZoom(
      targetZoom,
    );
  }

  // ==========================================================================
  // HOTSPOT'A BAK
  // ==========================================================================

  bool focusHotspotTo(
      int targetPanoId, {
        Duration duration =
        const Duration(milliseconds: 0),
      }) {
    if (_isTransitioning) {
      return false;
    }

    final match = widget.hotspots.firstWhere(
          (h) =>
      h.panoId == _panoId &&
          h.targetPanoId == targetPanoId,
      orElse: () => const PanoHotspot(
        panoId: -1,
        targetPanoId: -1,
        latitude: 0,
        longitude: 0,
      ),
    );

    if (match.panoId == -1) {
      return false;
    }

    _setProgrammaticDriving(true);

    _animateLookTo(
      _autoHotspotLongitude(match),
      _autoHotspotLatitude(match),
      duration: duration,
    );

    return true;
  }

  // ==========================================================================
  // FOCUS İPTAL
  // ==========================================================================

  void cancelFocus() {
    _lookCtrl?.stop();

    _lookCtrl?.dispose();

    _lookCtrl = null;

    _setProgrammaticDriving(false);
  }

  // ==========================================================================
  // KAMERAYI HOTSPOT'A ÇEVİR
  // ==========================================================================

  void _animateLookTo(
      double targetLon,
      double targetLat, {
        Duration duration =
        const Duration(milliseconds: 0),
      }) {
    cancelFocus();

    final startLon =
    _panoramaController.getLongitude();

    final startLat =
    _panoramaController.getLatitude();

    final normStartLon =
    _normalizeLon(startLon);

    final normTargetLon =
    _normalizeLon(targetLon);

    final deltaLon =
    _shortestDeltaDegrees(
      normStartLon,
      normTargetLon,
    );

    final deltaLat =
        targetLat - startLat;

    _setProgrammaticDriving(true);

    _lookCtrl = AnimationController(
      vsync: this,
      duration: duration,
    )
      ..addListener(() {
        final t = Curves.easeOutCubic.transform(
          _lookCtrl!.value,
        );

        final lon = _normalizeLon(
          normStartLon + deltaLon * t,
        );

        final lat = (
            startLat + deltaLat * t
        ).clamp(
          -90.0,
          90.0,
        );

        try {
          _panoramaController.setView(
            lat,
            lon,
          );
        } catch (_) {}
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          cancelFocus();
        }
      })
      ..forward();
  }

  // ==========================================================================
  // LONGITUDE NORMALIZE
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

  // ==========================================================================
  // EN KISA DÖNÜŞ AÇISI
  // ==========================================================================

  double _shortestDeltaDegrees(
      double from,
      double to,
      ) {
    var d = to - from;

    if (d > 180) {
      d -= 360;
    }

    if (d < -180) {
      d += 360;
    }

    return d;
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    if (widget.panoImages.isEmpty) {
      return const Center(
        child: Text(
          'Panorama bulunamadı',
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(
        widget.borderRadius,
      ),

      child: GestureDetector(
        behavior: HitTestBehavior.translucent,

        // --------------------------------------------------------------------
        // TEK TIK = ZOOM
        // --------------------------------------------------------------------

        onTap: _handleSingleTap,

        child: Stack(
          children: [
            // ================================================================
            // PANORAMA
            // ================================================================

            PanoramaViewer(
              panoramaController:
              _panoramaController,

              animSpeed:
              widget.animSpeed,

              sensitivity:
              widget.sensitivity,

              sensorControl:
              SensorControl.none,

              onViewChanged:
              _onViewChanged,

              hotspots:
              _buildHotspots(),

              child:
              widget.panoImages[_panoId],
            ),

            // ================================================================
            // LOADING
            // ================================================================

            if (_isLoading)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child:
                    CircularProgressIndicator(),
                  ),
                ),
              ),

            // ================================================================
            // BACK
            //
            // History boş değilse görünür.
            //
            // bottom: 10
            // Eski değer 20 idi.
            // Böylece buton 10 piksel aşağı taşındı.
            // ================================================================

            if (false)
              Positioned(
                bottom: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.88),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.65),
                          width: 1,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color.fromRGBO(0, 0, 0, 0.14),
                            blurRadius: 14,
                            offset: Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _goBack,
                          borderRadius: BorderRadius.circular(24),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 10,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.arrow_back_rounded,
                                  size: 18,
                                  color: Color(0xFF444444),
                                ),
                                SizedBox(width: 7),
                                Text(
                                  'Back',
                                  style: TextStyle(
                                    color: Color(0xFF444444),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // ================================================================
            // PANORAMA TRANSITION
            // ================================================================

            if (_isTransitioning &&
                _fromImage != null &&
                _toImage != null)
              Positioned.fill(
                child: PanoramaTransition(
                  fromImage:
                  _fromImage!,

                  toImage:
                  _toImage!,

                  savedLongitude:
                  _savedLongitude!,

                  savedLatitude:
                  _savedLatitude!,

                  savedZoom:
                  _savedZoom!,

                  hotspotLon:
                  _hotspotLon,

                  hotspotLat:
                  _hotspotLat,

                  borderRadius:
                  widget.borderRadius,

                  transitionDuration:
                  widget.transitionDuration,

                  onViewChanged:
                  _onViewChanged,

                  onCompleted:
                  _finishPanoTransition,
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

  bool get isCrossFloor =>
      targetFloorId != null;
}

// ============================================================================
// PANORAMA TRANSITION
// ============================================================================

class PanoramaTransition extends StatefulWidget {
  final Image fromImage;
  final Image toImage;

  final double savedLongitude;
  final double savedLatitude;
  final double savedZoom;

  final VoidCallback onCompleted;

  final Function(
      double lon,
      double lat,
      double zoom,
      )? onViewChanged;

  final double? hotspotLon;
  final double? hotspotLat;

  final double borderRadius;

  final Duration transitionDuration;

  const PanoramaTransition({
    required this.fromImage,
    required this.toImage,
    required this.savedLongitude,
    required this.savedLatitude,
    required this.savedZoom,
    required this.onCompleted,
    this.onViewChanged,
    this.hotspotLon,
    this.hotspotLat,
    this.borderRadius = 16.0,
    this.transitionDuration =
    const Duration(milliseconds: 1200),
    super.key,
  });

  @override
  State<PanoramaTransition> createState() =>
      _PanoramaTransitionState();
}

// ============================================================================
// TRANSITION STATE
// ============================================================================

class _PanoramaTransitionState
    extends State<PanoramaTransition>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  late Animation<double> _anim;

  late Animation<Offset> _perspectiveAnim;

  late PanoramaController _transitionController;

  double _perspectiveAmplification = 1.5;

  // ==========================================================================
  // INIT
  // ==========================================================================

  @override
  void initState() {
    super.initState();

    _transitionController =
        PanoramaController();

    _ctrl = AnimationController(
      vsync: this,
      duration: widget.transitionDuration,
    )
      ..addStatusListener((status) {
        if (status ==
            AnimationStatus.completed) {
          widget.onCompleted();
        }
      });

    _anim = CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeIn,
    );

    final hotspotDirection =
    _calculateDirection();

    _perspectiveAnim = Tween<Offset>(
      begin: Offset.zero,
      end: hotspotDirection,
    ).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Curves.easeIn,
      ),
    );

    _ctrl.forward();
  }

  // ==========================================================================
  // DIRECTION
  // ==========================================================================

  Offset _calculateDirection() {
    if (widget.hotspotLon != null &&
        widget.hotspotLat != null) {
      final lonDiff =
          widget.hotspotLon! -
              widget.savedLongitude;

      final latDiff =
          widget.hotspotLat! -
              widget.savedLatitude;

      double normalizedLonDiff =
          lonDiff;

      if (lonDiff > 180) {
        normalizedLonDiff =
            lonDiff - 360;
      } else if (lonDiff < -180) {
        normalizedLonDiff =
            lonDiff + 360;
      }

      final screenX =
          normalizedLonDiff / 180.0;

      final screenY =
          latDiff / 90.0;

      final amplifiedX =
      (screenX *
          2.0 *
          _perspectiveAmplification)
          .clamp(
        -3.15,
        3.15,
      );

      final amplifiedY =
      (screenY *
          2.0 *
          _perspectiveAmplification)
          .clamp(
        -3.15,
        3.15,
      );

      return Offset(
        -amplifiedX,
        amplifiedY,
      );
    }

    _perspectiveAmplification = 1.0;

    return const Offset(
      0,
      -0.8,
    );
  }

  // ==========================================================================
  // PERSPECTIVE MATRIX
  // ==========================================================================

  Matrix4 _createPerspectiveMatrix(
      Offset perspective,
      double intensity,
      ) {
    return Matrix4.identity()
      ..setEntry(
        3,
        2,
        0.002 *
            _perspectiveAmplification,
      )
      ..translate(
        perspective.dx *
            intensity *
            150 *
            _perspectiveAmplification,

        perspective.dy *
            intensity *
            75 *
            _perspectiveAmplification,

        intensity *
            -75 *
            _perspectiveAmplification,
      );
  }

  Matrix4 _createReversePerspectiveMatrix(
      Offset perspective,
      double intensity,
      ) {
    return Matrix4.identity()
      ..setEntry(
        3,
        2,
        0.002 *
            _perspectiveAmplification,
      )
      ..translate(
        -perspective.dx *
            intensity *
            150 *
            _perspectiveAmplification,

        -perspective.dy *
            intensity *
            150 *
            _perspectiveAmplification,

        intensity *
            75 *
            _perspectiveAmplification,
      );
  }

  // ==========================================================================
  // TRANSITION VIEW
  // ==========================================================================

  void _onTransitionViewChanged(
      double longitude,
      double latitude,
      double tilt,
      ) {
    final zoom =
    _transitionController.getZoom();

    widget.onViewChanged?.call(
      longitude,
      latitude,
      zoom,
    );
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,

      builder: (context, _) {
        final t =
            _anim.value;

        final perspective =
            _perspectiveAnim.value;

        const progressToSecondPano =
        0.1;

        final firstHalf =
        (t * 2.0).clamp(
          0.0,
          1.0,
        );

        final secondHalf =
        ((t -
            progressToSecondPano) *
            2.0)
            .clamp(
          0.0,
          1.0,
        );

        final showSecondPano =
            t >= progressToSecondPano;

        return Stack(
          children: [
            // ================================================================
            // FIRST PANO
            // ================================================================

            Positioned.fill(
              child: Transform(
                alignment:
                Alignment.center,

                transform:
                _createPerspectiveMatrix(
                  perspective,
                  firstHalf,
                ),

                child: PanoramaViewer(
                  panoramaController:
                  _transitionController,

                  sensitivity: 0,

                  animSpeed: 0,

                  sensorControl:
                  SensorControl.none,

                  longitude:
                  widget.savedLongitude,

                  latitude:
                  widget.savedLatitude,

                  zoom:
                  widget.savedZoom,

                  onViewChanged:
                  _onTransitionViewChanged,

                  child:
                  widget.fromImage,
                ),
              ),
            ),

            // ================================================================
            // SECOND PANO
            // ================================================================

            if (showSecondPano)
              Positioned.fill(
                child: Opacity(
                  opacity: secondHalf,

                  child: Transform(
                    alignment:
                    Alignment.center,

                    transform:
                    _createReversePerspectiveMatrix(
                      perspective,
                      1 - secondHalf,
                    ),

                    child:
                    PanoramaViewer(
                      panoramaController:
                      _transitionController,

                      sensitivity: 0,

                      animSpeed: 0,

                      sensorControl:
                      SensorControl.none,

                      longitude:
                      widget.savedLongitude,

                      latitude:
                      widget.savedLatitude,

                      zoom:
                      widget.savedZoom,

                      onViewChanged:
                      _onTransitionViewChanged,

                      child:
                      widget.toImage,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // ==========================================================================
  // DISPOSE
  // ==========================================================================

  @override
  void dispose() {
    _transitionController.dispose();

    _ctrl.dispose();

    super.dispose();
  }
}