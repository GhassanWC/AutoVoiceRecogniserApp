import 'package:flutter/services.dart';

/// iOS thermal/battery/memory snapshot for on-device AI instrumentation.
class DeviceStats {
  const DeviceStats({
    required this.thermalState,
    required this.batteryPercent,
    required this.memoryFootprintMb,
  });

  /// nominal | fair | serious | critical | unknown
  final String thermalState;

  /// 0..100, or -1 when unavailable (simulator).
  final int batteryPercent;

  /// App memory footprint in MB, or -1 when unavailable.
  final int memoryFootprintMb;

  @override
  String toString() =>
      'thermal=$thermalState battery=$batteryPercent% ram=${memoryFootprintMb}MB';
}

/// Reads ProcessInfo.thermalState, UIDevice battery and task memory from the
/// native side. Everything degrades gracefully where unsupported.
class DeviceStatsService {
  static const MethodChannel _channel = MethodChannel('app.livetranslator/devicestats');

  Future<DeviceStats> read() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('getStats');
      return DeviceStats(
        thermalState: raw?['thermalState'] as String? ?? 'unknown',
        batteryPercent: raw?['batteryPercent'] as int? ?? -1,
        memoryFootprintMb: raw?['memoryFootprintMb'] as int? ?? -1,
      );
    } catch (_) {
      return const DeviceStats(thermalState: 'unknown', batteryPercent: -1, memoryFootprintMb: -1);
    }
  }
}
