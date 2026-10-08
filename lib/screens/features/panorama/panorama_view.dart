import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../../models/houses_store.dart';
import 'dart:ui';
import '../../../features/panorama/components/panorama_engine.dart';
import '../../../features/panorama/components/floor_selector.dart';
import '../../../features/panorama/components/timeline.dart';
import '../../../features/panorama/components/compass_navigator.dart';
import '../../../features/panorama/theme/ui_styles.dart';
import '../../../models/panorama_data.dart';

class PanoramaViewScreen extends StatefulWidget {
  final PanoramaData? initialHouse;
  final String title;
  final int initialFloor;
  final int initialTimelineIndex;
  final int initialPanoId;

  const PanoramaViewScreen({
    super.key,
    required this.title,
    this.initialHouse,
    this.initialFloor = 0,
    this.initialTimelineIndex = 0,
    this.initialPanoId = 0,
  });

  @override
  State<PanoramaViewScreen> createState() => _PanoramaViewScreenState();
}

class _PanoramaViewScreenState extends State<PanoramaViewScreen>
    with TickerProviderStateMixin {
  int _currentFloor = 0;
  int _currentTimelineIndex = 0;
  int _currentPanoId = 0;
  bool _showFloorSelector = false;
  bool _showTimelineScroller = true;

  String _previewedRoomDescription = '';
  bool _showRoomDescription = false;

  bool _isManualToggle = false;
  double? _lastLon;
  double? _lastLat;
  double? _lastZoom;
  bool _hasInitializedView = false;

  late AnimationController _floorSelectorAnimationController;
  late AnimationController _timelineAnimationController;
  late AnimationController _appBarHeightAnimationController;
  late Animation<double> _floorSelectorFadeAnimation;
  late Animation<double> _timelineFadeAnimation;
  late Animation<double> _appBarHeightAnimation;

  final GlobalKey _timelineKey = GlobalKey();
  final GlobalKey<PanoramaEngineState> _engineKey =
      GlobalKey<PanoramaEngineState>();

  int? _compassPreviewRequestId;

  final Map<int, int> _lastRoomByFloor = {};

  late final PanoramaData _store;

  bool _roomInfoExpanded = true;

  bool _hideInfoBox = false;

  String get _currentRoomDescription {
    final rooms = _currentRooms;
    if (_currentPanoId < 0 || _currentPanoId >= rooms.length) return '';
    return rooms[_currentPanoId].description;
  }

  @override
  void initState() {
    super.initState();
    _store = widget.initialHouse ??
        (HousesStore.instance.selectedHouse ?? PanoramaData());
    _currentFloor = widget.initialFloor;
    _currentTimelineIndex = widget.initialTimelineIndex;
    _currentPanoId = widget.initialPanoId;

    _floorSelectorAnimationController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _timelineAnimationController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _appBarHeightAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _floorSelectorFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _floorSelectorAnimationController,
        curve: Curves.easeOutCubic,
      ),
    );

    _timelineFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _timelineAnimationController,
        curve: Curves.easeOutCubic,
      ),
    );

    _appBarHeightAnimation = Tween<double>(
      begin: 36.0,
      end: 98.0,
    ).animate(
      CurvedAnimation(
        parent: _appBarHeightAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    _timelineAnimationController.value = 1.0;
    _appBarHeightAnimationController.value = 1.0;
    _floorSelectorAnimationController.value = 0.0;

    _lastRoomByFloor[_currentFloor] = _currentPanoId;

    _store.addListener(_onStoreChanged);
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _floorSelectorAnimationController.dispose();
    _timelineAnimationController.dispose();
    _appBarHeightAnimationController.dispose();
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  List<RoomData> get _currentRooms {
    return _store.floorRooms[_currentFloor] ?? const <RoomData>[];
  }

  List<Image> get _currentPanoImages {
    return _currentRooms
        .map((room) => Image.file(File(room.imagePath)))
        .toList();
  }

  List<PanoHotspot> get _currentHotspots {
    final hotspotData =
        _store.floorHotspots[_currentFloor] ?? const <HotspotData>[];
    return hotspotData
        .map(
          (hotspot) => PanoHotspot(
            panoId: hotspot.fromRoomId,
            targetPanoId: hotspot.toRoomId,
            latitude: hotspot.latitude,
            longitude: hotspot.longitude,
            text: hotspot.text,
            icon: hotspot.icon,
            targetFloorId: hotspot.targetFloorId,
          ),
        )
        .toList();
  }

  List<int> _getConnectedRooms(int currentRoomId) {
    if (currentRoomId >= _currentRooms.length) return [];

    final currentRoom = _currentRooms[currentRoomId];
    return currentRoom.connectedRoomIds
        .where((id) => id < _currentRooms.length)
        .toList();
  }

  List<TimelineItem> get _currentTimelineItems {
    List<TimelineItem> items = [];

    for (int i = 0; i < _currentRooms.length; i++) {
      final room = _currentRooms[i];
      items.add(TimelineItem(icon: room.icon, text: room.name));
    }

    return items;
  }

  void _onFloorChanged(int floor) {
    final bool firstVisit = !_lastRoomByFloor.containsKey(floor);
    final int targetRoomId = firstVisit ? 0 : _lastRoomByFloor[floor]!;

    setState(() {
      _currentFloor = floor;
      _currentPanoId = targetRoomId;
      _currentTimelineIndex = targetRoomId;
      _compassPreviewRequestId = null;
      _showRoomDescription = false;
    });

    _lastRoomByFloor[floor] = targetRoomId;

    (_timelineKey.currentState as dynamic)?.updateIndex(_currentTimelineIndex);
    (_timelineKey.currentState as dynamic)?.clearPreview();

    debugPrint(
      "Floor changed to: $floor, room: $targetRoomId (firstVisit=$firstVisit)",
    );
  }

  int _encodeId(int floor, int room) => (floor << 16) | (room & 0xFFFF);
  int _decodeFloor(int encoded) => (encoded >> 16) & 0xFFFF;
  int _decodeRoom(int encoded) => encoded & 0xFFFF;

  void _onTimelineIndexChanged(int index) {
    setState(() => _compassPreviewRequestId = _encodeId(_currentFloor, index));

    (_timelineKey.currentState as dynamic)?.updateIndex(_currentTimelineIndex);
    (_timelineKey.currentState as dynamic)?.setPreview(index);

    _setCompassFaded(false);
    debugPrint(
      "Timeline preview requested for: $index (no travel, via compass)",
    );
  }

  List<CompassRoom> get _compassRooms {
    final sameFloorIds = _getConnectedRooms(_currentPanoId);
    final result = <CompassRoom>[];

    for (final id in sameFloorIds) {
      final room = _currentRooms
          .where((r) => r.id == id)
          .cast<RoomData?>()
          .firstWhere((r) => r != null, orElse: () => null);
      if (room != null) {
        result.add(
          CompassRoom(
            id: _encodeId(_currentFloor, room.id),
            name: room.name,
            icon: room.icon,
            description: 'Go to ${room.name}',
            isCrossFloor: false,
          ),
        );
      }
    }

    final cross = _store.floorHotspots[_currentFloor] ?? const <HotspotData>[];
    for (final h in cross) {
      if (h.fromRoomId != _currentPanoId) continue;
      if (h.targetFloorId == null) continue;

      final tf = h.targetFloorId!;
      final tRooms = _store.floorRooms[tf] ?? const <RoomData>[];
      if (tRooms.isEmpty || h.toRoomId < 0 || h.toRoomId >= tRooms.length) {
        continue;
      }
      final tRoom = tRooms[h.toRoomId];

      result.add(
        CompassRoom(
          id: _encodeId(tf, h.toRoomId),
          name: tRoom.name,
          icon: tRoom.icon,
          description: 'To ${tRoom.name} (Floor $tf)',
          isCrossFloor: true,
          targetFloorId: tf,
        ),
      );
    }

    return result;
  }

  void _clearPreviewUI() {
    _engineKey.currentState?.cancelFocus();

    if (_showRoomDescription ||
        _previewedRoomDescription.isNotEmpty ||
        _compassPreviewRequestId != null) {
      setState(() {
        _showRoomDescription = false;
        _previewedRoomDescription = '';
        _compassPreviewRequestId = null;
      });
    }

    (_timelineKey.currentState as dynamic)?.clearPreview();
  }

  void _onPanoChanged(int panoId) {
    void apply() {
      _clearPreviewUI();

      setState(() {
        _currentPanoId = panoId;
        _currentTimelineIndex = panoId.clamp(0, 9);
        _lastRoomByFloor[_currentFloor] = panoId;

        if (_hideInfoBox && _currentRoomDescription.trim().isNotEmpty) {
          _hideInfoBox = false;
          _roomInfoExpanded = true;
        } else if (_hideInfoBox && _currentRoomDescription.trim().isEmpty) {
          _hideInfoBox = true;
        }
      });
      (_timelineKey.currentState as dynamic)?.updateIndex(
        _currentTimelineIndex,
      );
      debugPrint("Panorama changed to: $panoId");
    }

    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle) {
      apply();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        apply();
      });
    }
  }

  bool _isCompassFaded = true;
  DateTime? _lastCompassInteractionAt;

  void _setCompassFaded(bool faded) {
    if (_isCompassFaded != faded) {
      setState(() => _isCompassFaded = faded);
    }
  }

  void _markCompassInteraction() {
    _lastCompassInteractionAt = DateTime.now();
    _setCompassFaded(false);
  }

  void _onViewChanged(double lon, double lat, double zoom) {
    if (!_hasInitializedView) {
      _lastLon = lon;
      _lastLat = lat;
      _lastZoom = zoom;
      _hasInitializedView = true;
      return;
    }

    double lonDiff = (lon - _lastLon!).abs();
    double latDiff = (lat - _lastLat!).abs();
    double zoomDiff = (zoom - _lastZoom!).abs();

    final now = DateTime.now();
    final bool recentCompassInteraction = _lastCompassInteractionAt != null &&
        now.difference(_lastCompassInteractionAt!).inMilliseconds < 1500;

    if (!recentCompassInteraction &&
        (lonDiff > .1 || latDiff > .1 || zoomDiff > 0.2)) {
      _setCompassFaded(true);

      _engineKey.currentState?.cancelFocus();
      if (_showRoomDescription) {
        setState(() => _showRoomDescription = false);
      }
      (_timelineKey.currentState as dynamic)?.clearPreview();

      if (_showFloorSelector && !_isManualToggle) {
        debugPrint("Auto-switching to timeline due to panorama interaction");
        _toggleTimelineScroller();
      }
    }

    _lastLon = lon;
    _lastLat = lat;
    _lastZoom = zoom;
  }

  void _toggleFloorSelector() {
    if (_showFloorSelector) return;

    setState(() {
      _showFloorSelector = true;
      _showTimelineScroller = false;
    });

    _timelineAnimationController.reverse();
    _floorSelectorAnimationController.forward();
    _appBarHeightAnimationController.reverse();
  }

  void _toggleTimelineScroller() {
    if (_showTimelineScroller) return;

    setState(() {
      _showFloorSelector = false;
      _showTimelineScroller = true;
    });

    _floorSelectorAnimationController.reverse();
    _timelineAnimationController.forward();
    _appBarHeightAnimationController.forward();
  }

  void _onHotspotClicked(PanoHotspot hotspot) {
    debugPrint(
      "Hotspot clicked: ${hotspot.text} from pano ${hotspot.panoId} to pano ${hotspot.targetPanoId} (targetFloor=${hotspot.targetFloorId})",
    );

    if (!_hideInfoBox) {
      setState(() {
        _hideInfoBox = true;
      });
    }

    if (hotspot.targetFloorId != null &&
        hotspot.targetFloorId != _currentFloor) {
      final int destFloor = hotspot.targetFloorId!;
      final int destRoomId = hotspot.targetPanoId
          .clamp(0, (_store.floorRooms[destFloor]?.length ?? 1) - 1);

      setState(() {
        _currentFloor = destFloor;
        _currentPanoId = destRoomId;
        _currentTimelineIndex = destRoomId;
        _compassPreviewRequestId = null;
        _showRoomDescription = false;
      });

      _lastRoomByFloor[_currentFloor] = destRoomId;
      (_timelineKey.currentState as dynamic)
          ?.updateIndex(_currentTimelineIndex);
      (_timelineKey.currentState as dynamic)?.clearPreview();

      _toggleTimelineScroller();

      return;
    }

    _toggleTimelineScroller();
    _clearPreviewUI();
    _setCompassFaded(true);
  }

  void _onCompassRoomSelected(int encodedId) {
    _markCompassInteraction();

    final floor = _decodeFloor(encodedId);
    final room = _decodeRoom(encodedId);

    (_timelineKey.currentState as dynamic)?.clearPreview();

    if (floor != _currentFloor) {
      final destRooms = _store.floorRooms[floor] ?? const <RoomData>[];
      final destRoomId =
          room.clamp(0, (destRooms.isEmpty ? 0 : destRooms.length - 1));
      setState(() {
        _currentFloor = floor;
        _currentPanoId = destRoomId;
        _currentTimelineIndex = destRoomId;
      });
      _lastRoomByFloor[_currentFloor] = destRoomId;
      (_timelineKey.currentState as dynamic)
          ?.updateIndex(_currentTimelineIndex);
      _toggleTimelineScroller();
      return;
    }

    final transitioned = _engineKey.currentState?.navigateTo(room) ?? false;
    if (!transitioned) {
      setState(() {
        _currentPanoId = room;
        _currentTimelineIndex = room.clamp(0, _currentTimelineItems.length - 1);
      });
      (_timelineKey.currentState as dynamic)
          ?.updateIndex(_currentTimelineIndex);
    }
    if (_showRoomDescription) {
      setState(() => _showRoomDescription = false);
    }
  }

  void _onCompassRoomPreview(int encodedId) {
    _markCompassInteraction();

    final floor = _decodeFloor(encodedId);
    final room = _decodeRoom(encodedId);

    if (floor == _currentFloor) {
      _engineKey.currentState?.focusHotspotTo(
        room,
        duration: const Duration(milliseconds: 400),
      );

      final r = _currentRooms.firstWhere(
        (r) => r.id == room,
        orElse: () => _currentRooms.first,
      );
      setState(() {
        _previewedRoomDescription = r.name;
        _showRoomDescription = true;
      });
      final idx = room.clamp(0, _currentTimelineItems.length - 1);
      (_timelineKey.currentState as dynamic)?.setPreview(idx);
    } else {
      _engineKey.currentState?.focusHotspotTo(
        room,
        duration: const Duration(milliseconds: 400),
      );

      final rs = _store.floorRooms[floor] ?? const <RoomData>[];
      if (rs.isNotEmpty && room >= 0 && room < rs.length) {
        setState(() {
          _previewedRoomDescription = rs[room].name;
          _showRoomDescription = true;
        });
      }
    }
  }

  void _onCompassPreviewClear() {
    _markCompassInteraction();

    _engineKey.currentState?.cancelFocus();

    if (_showRoomDescription) {
      setState(() => _showRoomDescription = false);
    }
    (_timelineKey.currentState as dynamic)?.clearPreview();
  }

  @override
  Widget build(BuildContext context) {
    double bottomPadding = 60.0;

    const double _compassBottom = 140.0;
    const double _compassHeight = 86.0;
    final double _infoBottom = _compassBottom + _compassHeight + 8.0;

    return Scaffold(
      backgroundColor: Colors.white,
      extendBodyBehindAppBar: false,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(68),
        child: AnimatedBuilder(
          animation: _appBarHeightAnimation,
          builder: (context, child) {
            return ClipRect(
              child: SizedBox(
                height: _appBarHeightAnimation.value,
                child: SafeArea(
                  child: Column(
                    children: [
                      Container(
                        height: 36,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 0,
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.arrow_back,
                                color: Colors.black,
                                size: 20,
                              ),
                              onPressed: () => Navigator.of(context).pop(),
                              iconSize: 20,
                              padding: const EdgeInsets.all(4),
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                widget.title,
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(width: 32),
                          ],
                        ),
                      ),
                      if (_showTimelineScroller)
                        Expanded(
                          child: FadeTransition(
                            opacity: _timelineFadeAnimation,
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 0,
                              ),
                              child: Center(
                                child: Timeline(
                                  key: _timelineKey,
                                  initialIndex: _currentTimelineIndex,
                                  onIndexChanged: _onTimelineIndexChanged,
                                  connectedItems: _getConnectedRooms(
                                    _currentPanoId,
                                  ),
                                  items: _currentTimelineItems,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      body: Stack(
        children: [
          Container(
            padding: const EdgeInsets.all(4.0),
            child: PanoramaEngine(
              key: _engineKey,
              panoImages: _currentPanoImages,
              hotspots: _currentHotspots,
              initialPanoId: _currentPanoId,
              onPanoChanged: _onPanoChanged,
              onViewChanged: _onViewChanged,
              onHotspotClicked: _onHotspotClicked,
              borderRadius: 16.0,
              sensitivity: 1.0,
              transitionDuration: const Duration(milliseconds: 1200),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: _compassBottom,
            child: Center(
              child: AnimatedOpacity(
                opacity: _isCompassFaded
                    ? (_showTimelineScroller ? 0.25 : 0.0)
                    : (_showTimelineScroller ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: CompassNavigator(
                  rooms: _compassRooms,
                  currentRoomId: _encodeId(_currentFloor, _currentPanoId),
                  previewActive: _showRoomDescription,
                  externalPreviewRoomId: _compassPreviewRequestId,
                  onExternalPreviewHandled: () =>
                      setState(() => _compassPreviewRequestId = null),
                  onRoomSelected: _onCompassRoomSelected,
                  onRoomPreview: _onCompassRoomPreview,
                  onPreviewClear: _onCompassPreviewClear,
                  width: 300,
                  height: _compassHeight,
                ),
              ),
            ),
          ),
          if (_showFloorSelector)
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomPadding + 80,
              child: FadeTransition(
                opacity: _floorSelectorFadeAnimation,
                child: Center(
                  child: FloorSelector(
                    floors: _store.floorRooms.length,
                    floorRooms: _store.floorRooms.entries
                        .map((e) => e.value.map((r) => r.name).toList())
                        .toList(),
                    initialFloor: _currentFloor,
                    onFloorChanged: _onFloorChanged,
                    selectedColor: Colors.grey.shade700,
                    unselectedColor: Colors.grey,
                    maxWidth: 350,
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomPadding,
            child: Center(
              child: Builder(
                builder: (context) {
                  final useGlass = _showTimelineScroller && !_showFloorSelector;
                  final radius = AppStyles.pillRadius;

                  final containerChild = Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: _showTimelineScroller
                              ? AppStyles.controlBgActive
                              : AppStyles.controlBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: IconButton(
                          icon: Icon(
                            Icons.timeline,
                            color: _showTimelineScroller
                                ? AppStyles.accentActive
                                : Colors.black,
                            size: 20,
                          ),
                          onPressed: _toggleTimelineScroller,
                          tooltip: 'Rooms',
                          iconSize: 20,
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: _showFloorSelector
                              ? AppStyles.accentActive.withOpacity(0.12)
                              : AppStyles.controlBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Tooltip(
                          message: 'Floor Selector',
                            child: Transform.translate(
                              offset: const Offset(0, 0), // 12 piksel yukarı
                              child: TextButton.icon(
                                onPressed: _toggleFloorSelector,
                                icon: Icon(
                                  Icons.layers,
                                  color: _showFloorSelector
                                      ? AppStyles.accentActive
                                      : Colors.white70,
                                  size: 20,
                                ),
                                label: Text(
                                  'Select Floor',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: _showFloorSelector
                                        ? AppStyles.accentActive
                                        : Colors.white70,
                                  ),
                                ),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 16,
                                  ),
                                  minimumSize: const Size(36, 36),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ),
                        ),
                      ),
                    ],
                  );

                  if (useGlass) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color.fromRGBO(0, 0, 0, 0.28),
                                Color.fromRGBO(0, 0, 0, 0.18),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(radius),
                            border: Border.all(
                              color: const Color.fromRGBO(255, 255, 255, 0.45),
                              width: AppStyles.borderWidth,
                            ),
                            boxShadow: [
                              const BoxShadow(
                                color: Color.fromRGBO(0, 0, 0, 0.10),
                                blurRadius: 20,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: containerChild,
                        ),
                      ),
                    );
                  }

                  return ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppStyles.surface,
                        borderRadius: BorderRadius.circular(radius),
                        border: Border.all(
                          color: AppStyles.border,
                          width: AppStyles.borderWidth,
                        ),
                        boxShadow: [AppStyles.shadow],
                      ),
                      child: containerChild,
                    ),
                  );
                },
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: _infoBottom,
            child: AnimatedOpacity(
              opacity: _showTimelineScroller &&
                      !_hideInfoBox &&
                      _currentRoomDescription.trim().isNotEmpty
                  ? 1.0
                  : 0.0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: IgnorePointer(
                ignoring: !_showTimelineScroller ||
                    _hideInfoBox ||
                    _currentRoomDescription.trim().isEmpty,
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.5,
                    child: _RoomInfoBox(
                      expanded: _roomInfoExpanded,
                      title: _currentRooms
                              .where((r) => r.id == _currentPanoId)
                              .map((r) => r.name)
                              .cast<String?>()
                              .firstWhere((e) => e != null, orElse: () => '') ??
                          '',
                      description: _currentRoomDescription,
                      onToggle: () => setState(() {
                        _roomInfoExpanded = !_roomInfoExpanded;
                      }),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomInfoBox extends StatelessWidget {
  final bool expanded;
  final String title;
  final String description;
  final VoidCallback onToggle;

  const _RoomInfoBox({
    required this.expanded,
    required this.title,
    required this.description,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final hasTitle = title.trim().isNotEmpty;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.fromRGBO(0, 0, 0, 0.28),
                Color.fromRGBO(0, 0, 0, 0.18),
              ],
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color.fromRGBO(255, 255, 255, 0.45),
              width: AppStyles.borderWidth,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color.fromRGBO(0, 0, 0, 0.10),
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: onToggle,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 18, color: Colors.white),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          hasTitle
                              ? 'About ${title.trim()}'
                              : 'Room information',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: Colors.white70,
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: Container(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    description,
                    style: const TextStyle(
                      color: Colors.white70,
                      height: 1.35,
                      fontSize: 13.5,
                    ),
                    textAlign: TextAlign.left,
                  ),
                ),
                crossFadeState: expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 180),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
