import 'package:flutter/material.dart';
import 'editor_models.dart';

class RoomData {
  final int id;
  final String name;
  final String imagePath;
  final IconData icon;
  final List<int> connectedRoomIds;

  final String description;

  final int presetId;

  const RoomData({
    required this.id,
    required this.name,
    required this.imagePath,
    required this.icon,
    required this.connectedRoomIds,
    this.description = '',
    this.presetId = -1,
  });
}

class HotspotData {
  final int fromRoomId;
  final int toRoomId;
  final double latitude;
  final double longitude;
  final String text;
  final IconData icon;

  final int? targetFloorId;

  const HotspotData({
    required this.fromRoomId,
    required this.toRoomId,
    required this.latitude,
    required this.longitude,
    required this.text,
    required this.icon,
    this.targetFloorId,
  });
}

class PanoramaData extends ChangeNotifier {
  String houseName = '';
  String houseAddress = '';
  String houseArea = '';
  String houseThumbnail = '';

  final Map<int, List<RoomData>> floorRooms = {};
  final Map<int, List<HotspotData>> floorHotspots = {};

  PanoramaData();

  void replaceFromEditors(List<FloorEditor> floors,
      {String? name, String? address, String? area, String? thumbnail}) {
    floorRooms.clear();
    floorHotspots.clear();

    houseName = name ?? houseName;
    houseAddress = address ?? houseAddress;
    houseArea = area ?? houseArea;
    houseThumbnail = thumbnail ?? houseThumbnail;

    for (int fIdx = 0; fIdx < floors.length; fIdx++) {
      _setFloorFromEditorInternal(fIdx, floors[fIdx]);
    }
    notifyListeners();
  }

  void replaceFloorFromEditor(int floorIdx, FloorEditor floor) {
    _setFloorFromEditorInternal(floorIdx, floor);
    notifyListeners();
  }

  /// Gezinti ekranında yerleştirilen halka konumlarını kaydeder.
  /// [rings] anahtarı "from>to", değeri [boylam, enlem] şeklindedir.
  void setRingPositions(int floor, Map<String, List<double>> rings) {
    final list = List<HotspotData>.from(floorHotspots[floor] ?? const []);
    final done = <String>{};

    for (int i = 0; i < list.length; i++) {
      final h = list[i];
      if (h.targetFloorId != null) continue;

      final key = '${h.fromRoomId}>${h.toRoomId}';
      final p = rings[key];
      if (p == null) continue;

      list[i] = HotspotData(
        fromRoomId: h.fromRoomId,
        toRoomId: h.toRoomId,
        latitude: p[1],
        longitude: p[0],
        text: h.text,
        icon: h.icon,
      );
      done.add(key);
    }

    // Hotspot'u olmayan bağlantılar için yenisini ekle.
    rings.forEach((key, p) {
      if (done.contains(key)) return;
      final parts = key.split('>');
      list.add(HotspotData(
        fromRoomId: int.parse(parts[0]),
        toRoomId: int.parse(parts[1]),
        latitude: p[1],
        longitude: p[0],
        text: '',
        icon: Icons.circle_outlined,
      ));
    });

    floorHotspots[floor] = list;
    notifyListeners();
  }

  void _setFloorFromEditorInternal(int floorIdx, FloorEditor floor) {
    final rooms = <RoomData>[];
    for (int rIdx = 0; rIdx < floor.rooms.length; rIdx++) {
      final r = floor.rooms[rIdx];
      final name = r.name.isNotEmpty ? r.name : 'Pano $rIdx';
      final image = r.imagePath.isNotEmpty
          ? r.imagePath
          : 'assets/panoramas/placeholder.jpg';
      final icon = kIconCatalog[r.iconName] ?? Icons.circle_outlined;

      final conns = floor.hotspots
          .where((h) => h.fromRoomId == rIdx && !(h.changeFloor == true))
          .map((h) => h.toRoomId)
          .where((to) => to >= 0 && to < floor.rooms.length)
          .toSet()
          .toList()
        ..sort();

      rooms.add(RoomData(
        id: rIdx,
        name: name,
        imagePath: image,
        icon: icon,
        connectedRoomIds: conns,
        description: r.description,
        presetId: r.presetId,
      ));
    }

    final hs = <HotspotData>[];
    for (final h in floor.hotspots) {
      final fromId = h.fromRoomId
          .clamp(0, (floor.rooms.isEmpty ? 0 : floor.rooms.length - 1));

      final int destFloor =
          (h.changeFloor ? (h.targetFloorId ?? floorIdx) : floorIdx);
      final int toId = h.toRoomId;

      final text = h.text.isNotEmpty ? h.text : 'To $toId';

      IconData targetRoomIcon = Icons.circle_outlined;
      if (destFloor == floorIdx) {
        if (toId >= 0 && toId < floor.rooms.length) {
          targetRoomIcon =
              kIconCatalog[floor.rooms[toId].iconName] ?? Icons.circle_outlined;
        }
      } else {
        final targetRooms = floorRooms[destFloor];
        if (targetRooms != null && toId >= 0 && toId < targetRooms.length) {
          targetRoomIcon = targetRooms[toId].icon;
        }
      }

      hs.add(HotspotData(
        fromRoomId: fromId,
        toRoomId: toId,
        latitude: h.latitude,
        longitude: h.longitude,
        text: text,
        icon: targetRoomIcon,
        targetFloorId: h.changeFloor ? destFloor : null,
      ));
    }

    floorRooms[floorIdx] = rooms;
    floorHotspots[floorIdx] = hs;
  }

  Map<String, dynamic> toJson() => {
        'houseName': houseName,
        'houseAddress': houseAddress,
        'houseArea': houseArea,
        'houseThumbnail': houseThumbnail,
        'floorRooms': floorRooms.map((k, v) => MapEntry(
            '$k',
            v
                .map((r) => {
                      'id': r.id,
                      'imagePath': r.imagePath,
                      'name': r.name,
                      'icon': {
                        'codePoint': r.icon.codePoint,
                        'fontFamily': r.icon.fontFamily,
                      },
                      'connectedRoomIds': r.connectedRoomIds,
                      'description': r.description,
                      'presetId': r.presetId,
                    })
                .toList())),
        'floorHotspots': floorHotspots.map((k, v) => MapEntry(
            '$k',
            v
                .map((h) => {
                      'fromRoomId': h.fromRoomId,
                      'toRoomId': h.toRoomId,
                      'latitude': h.latitude,
                      'longitude': h.longitude,
                      'text': h.text,
                      'icon': {
                        'codePoint': h.icon.codePoint,
                        'fontFamily': h.icon.fontFamily,
                      },
                      'targetFloorId': h.targetFloorId,
                    })
                .toList())),
      };

  static PanoramaData fromJson(Map<String, dynamic> json) {
    final data = PanoramaData();
    data.houseName = json['houseName'] ?? '';
    data.houseAddress = json['houseAddress'] ?? '';
    data.houseArea = json['houseArea'] ?? '';
    data.houseThumbnail = json['houseThumbnail'] ?? '';

    return data;
  }
}
