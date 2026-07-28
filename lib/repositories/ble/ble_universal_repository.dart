import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:universal_ble/universal_ble.dart';

import 'package:roll_feathers/repositories/ble/ble_repository.dart';
import 'package:roll_feathers/util/platform_info.dart';

class UniversalBleDevice implements BleDeviceWrapper {
  @override
  Logger log = Logger("UniversalBleDevice");

  @override
  String get deviceId => device.deviceId;

  @override
  List<String> get servicesUuids => _services.map((s) => s.uuid).toList();

  @override
  List<String> get characteristicUuids => _characteristics.map((c) => c.uuid).toList();

  @override
  bool initialized = false;
  BleDevice device;
  List<BleService> _services = [];
  List<BleCharacteristic> _characteristics = [];

  String? _serviceId;
  String? _writeCharacteristicId;
  String? _notifyCharacteristicId;

  final String? _cachedName;

  /// Platform facts, injected so the MTU negotiation below can be exercised in
  /// tests; defaults to the host, matching [BleUniversalRepository].
  final PlatformInfo _platform;

  UniversalBleDevice({required this.device, String? cachedName, PlatformInfo? platform})
      : _cachedName = cachedName,
        _platform = platform ?? PlatformInfo.host();

  /// Discover services and characteristics. Connection must already be established
  /// by [BleUniversalRepository] before calling this.
  @override
  Future<bool> init() async {
    _services = await UniversalBle.discoverServices(deviceId);
    log.fine("discovered ${_services.length} service(s)");
    _characteristics = _services.expand((s) => s.characteristics).toList();
    initialized = true;
    return initialized;
  }

  @override
  Future<void> discoverServices() async {
    _services = await UniversalBle.discoverServices(deviceId);
    _characteristics = _services.expand((s) => s.characteristics).toList();
    log.fine("discoverServices: ${_services.length} service(s)");
  }

  @override
  Future<void> setDeviceUuids({
    required String serviceUuid,
    required String notifyUuid,
    required String writeUuid,
  }) async {
    _serviceId = serviceUuid;
    _notifyCharacteristicId = notifyUuid;
    _writeCharacteristicId = writeUuid;
    // Negotiate the MTU before any message traffic — see [_requestAndroidMtu].
    await _requestAndroidMtu();
    await UniversalBle.subscribeNotifications(deviceId, serviceUuid, notifyUuid);
  }

  /// Android is the only platform where the ATT MTU must be requested explicitly:
  /// it defaults to 23 (a 20-byte payload), and `universal_ble` never negotiates on
  /// its own. CoreBluetooth (macOS/iOS) and the browser (web) negotiate at connect,
  /// and Windows/Linux expose no request API — so this is a no-op everywhere else.
  ///
  /// Without it, anything longer than 20 bytes is silently truncated in **both**
  /// directions: bulk animation-transfer writes land as garbage (while still acking
  /// correctly, because the offset field survives in the first 4 bytes), and inbound
  /// `IAmADie` loses its trailing battery fields. Failures are logged and swallowed —
  /// a die that refuses the request still works for everything that fits in 20 bytes,
  /// which is exactly how it behaved before.
  Future<void> _requestAndroidMtu() async {
    if (!_platform.isAndroid) return;
    try {
      final granted = await UniversalBle.requestMtu(deviceId, kPreferredMtu);
      if (granted < kMinUsefulMtu) {
        log.severe(
          'MTU negotiated to $granted — below the $kMinUsefulMtu a full bulk-transfer '
          'chunk needs. Animation transfers to this die will be corrupted.',
        );
      } else {
        log.info('MTU negotiated to $granted');
      }
    } catch (e, st) {
      log.warning('requestMtu failed (continuing at default MTU): $e', e, st);
    }
  }

  @override
  Future<void> writeMessage(List<int> data) async {
    if (_serviceId == null || _writeCharacteristicId == null) {
      throw StateError('setDeviceUuids must be called before writeMessage');
    }
    await UniversalBle.write(
      deviceId,
      _serviceId!,
      _writeCharacteristicId!,
      Uint8List.fromList(data),
      withoutResponse: true,
    );
  }

  @override
  Stream<List<int>> get notifyStream {
    if (_notifyCharacteristicId == null) {
      throw StateError('setDeviceUuids must be called before notifyStream');
    }
    return UniversalBle.characteristicValueStream(deviceId, _notifyCharacteristicId!);
  }

  @override
  Future<void> disconnect() async {
    await UniversalBle.disconnect(deviceId);
  }

  @override
  String get friendlyName => _cachedName ?? device.name ?? deviceId;
}

/// ATT MTU requested on Android at connect. This is a request, not a guarantee —
/// the peripheral decides. Pixels dice observed granting 128 (a 125-byte payload),
/// comfortably above [kMinUsefulMtu]; the granted value is logged at connect.
const int kPreferredMtu = 247;

/// Below this the largest message the app writes — a bulk-transfer chunk of 100
/// payload bytes plus its 4-byte header, plus 3 bytes of ATT overhead — no longer
/// fits in a single write and would be silently truncated.
const int kMinUsefulMtu = 107;

class BleUniversalRepository implements BleRepository {
  final _log = Logger("BleUniversalRepository");

  /// Platform facts injected by the composition root (see [DiWrapper.initDi]),
  /// so all platform branching here goes through one resolved-once source.
  final PlatformInfo _platform;

  BleUniversalRepository({PlatformInfo? platform}) : _platform = platform ?? PlatformInfo.host();

  final Map<String, UniversalBleDevice> _discoveredBleDevices = {};
  final Map<String, StreamSubscription<bool>> _connectionSubscriptions = {};
  // Cache device names across scans. Android BLE sometimes returns a null name
  // even when the device matched by namePrefix (name is in the OS cache but not
  // in the current advertisement packet). We populate this whenever we see a
  // non-null name so that re-scans can still identify the device correctly.
  final Map<String, String> _deviceNameCache = {};

  StreamSubscription<BleDevice>? _scanSubscription;
  Timer? _scanTimer;
  final List<BleDevice> _pendingConnect = [];

  @override
  Map<String, BleDeviceWrapper> get discoveredBleDevices => _discoveredBleDevices;
  final _bleDeviceSubscription = StreamController<Map<String, BleDeviceWrapper>>.broadcast();
  final _bleEnabledSubscription = StreamController<bool>.broadcast();

  @override
  bool enabled = false;
  @override
  bool supported = false;
  bool permissioned = false;

  @override
  Stream<Map<String, BleDeviceWrapper>> subscribeBleDevices() => _bleDeviceSubscription.stream;

  @override
  Stream<bool> subscribeBleEnabled() => _bleEnabledSubscription.stream;

  late StreamSubscription<AvailabilityState> _adapterStateSubscription;

  List<String>? _pendingScanServices;
  List<String>? _pendingScanNamePrefix;

  @override
  Future<void> init() async {
    // Set operation timeout before any connections.
    if (_platform.isDesktop) {
      UniversalBle.timeout = const Duration(seconds: 25);
    } else if (!_platform.isWeb) {
      UniversalBle.timeout = const Duration(seconds: 10);
    }

    if (_platform.isWeb) {
      // On web, BLE is user-gesture gated. Don't block; listen for state changes.
      _adapterStateSubscription = UniversalBle.availabilityStream.listen((state) {
        _updateAvailability(state);
        _bleEnabledSubscription.add(enabled && supported && permissioned);
      });
      supported = true;
      enabled = true;
      permissioned = true;
      _bleEnabledSubscription.add(true);
    } else {
      // Non-blocking: return immediately so the app can render.
      // Permissions check and queued scan are triggered when the adapter fires.
      _adapterStateSubscription = UniversalBle.availabilityStream.listen((state) async {
        final wasReady = enabled && supported;
        _updateAvailability(state);
        if (state == AvailabilityState.poweredOn && !wasReady) {
          if (!await UniversalBle.hasPermissions()) {
            await UniversalBle.requestPermissions();
          }
          permissioned = await UniversalBle.hasPermissions();
          _log.info('ble_repo BLE ready (supported=$supported, enabled=$enabled, permissioned=$permissioned)');
          _bleEnabledSubscription.add(enabled && supported && permissioned);
          _triggerPendingScan();
        } else {
          _bleEnabledSubscription.add(enabled && supported && permissioned);
        }
      });
      _bleEnabledSubscription.add(false);
      _log.info('ble_repo init returned (BLE adapter initializing asynchronously)');
    }
  }

  void _triggerPendingScan() {
    final services = _pendingScanServices;
    final namePrefix = _pendingScanNamePrefix;
    _pendingScanServices = null;
    _pendingScanNamePrefix = null;
    if (services != null || namePrefix != null) {
      unawaited(scan(services: services, namePrefix: namePrefix));
    }
  }

  @override
  Future<bool> isSupported() async {
    return supported;
  }

  void _updateAvailability(AvailabilityState state) {
    if (state == AvailabilityState.poweredOn) {
      supported = true;
      enabled = true;
    } else if (state == AvailabilityState.poweredOff) {
      enabled = false;
    } else if (state == AvailabilityState.unsupported ||
        state == AvailabilityState.unknown ||
        state == AvailabilityState.unauthorized) {
      supported = false;
      enabled = false;
    }
  }

  final Map<String, DateTime> _deviceLastSeen = {};

  @override
  Future<void> scan({List<String>? services, List<String>? namePrefix, Duration? timeout = const Duration(seconds: 5)}) async {
    if (!_platform.isWeb && (!supported || !enabled)) {
      _log.fine("scan() queued: BLE adapter not ready");
      _pendingScanServices = services;
      _pendingScanNamePrefix = namePrefix;
      return;
    }
    if (await UniversalBle.isScanning()) {
      _log.fine("scan() called while already scanning; ignoring");
      return;
    }

    _scanSubscription?.cancel();
    _scanTimer?.cancel();

    _scanSubscription = UniversalBle.scanStream.listen((BleDevice bleDevice) {
      final now = DateTime.now();
      final last = _deviceLastSeen[bleDevice.deviceId];
      if (last != null && now.difference(last) < const Duration(seconds: 2)) return;
      _deviceLastSeen[bleDevice.deviceId] = now;

      // Cache the name whenever the advertisement includes it.
      if (bleDevice.name != null && bleDevice.name!.isNotEmpty) {
        _deviceNameCache[bleDevice.deviceId] = bleDevice.name!;
      }

      final alreadyPending = _pendingConnect.any((d) => d.deviceId == bleDevice.deviceId);
      if (!_discoveredBleDevices.containsKey(bleDevice.deviceId) && !alreadyPending) {
        _log.info("discovered: ${_deviceNameCache[bleDevice.deviceId] ?? bleDevice.deviceId}");
        _pendingConnect.add(bleDevice);
        // On non-Windows native, connect immediately while scan continues.
        // iOS/macOS CoreBluetooth and Android BLE support connecting during scan.
        // Windows WinRT is less tolerant — it uses the batch path in _stopScanAndConnect.
        if (!_platform.isWeb && !_platform.isWindows) {
          unawaited(_connectDevice(bleDevice));
        }
      }
    });

    _log.info("ble scan start (services: ${services?.join(',') ?? 'any'})");
    try {
      await UniversalBle.startScan(scanFilter: ScanFilter(withServices: services ?? [], withNamePrefix: namePrefix ?? []));
    } catch (e, st) {
      // ignore: avoid_print
      print("[BLE] startScan error: $e");
      _log.severe("startScan error: $e", e, st);
      _scanSubscription?.cancel();
      _scanSubscription = null;
      if (!_platform.isWeb) rethrow;
      return;
    }

    // On web, startScan() awaits requestDevice() — by the time it returns the
    // device is already in _pendingConnect. Connect immediately, no timer needed.
    if (_platform.isWeb) {
      await _stopScanAndConnect();
      return;
    }

    _scanTimer = Timer(timeout ?? const Duration(seconds: 5), () async {
      await _stopScanAndConnect();
    });
  }

  Future<void> _connectDevice(BleDevice bleDevice) async {
    _pendingConnect.removeWhere((d) => d.deviceId == bleDevice.deviceId);
    try {
      await UniversalBle.connect(bleDevice.deviceId);
      _discoveredBleDevices[bleDevice.deviceId] =
          UniversalBleDevice(device: bleDevice, cachedName: _deviceNameCache[bleDevice.deviceId], platform: _platform);
      _bleDeviceSubscription.add(Map.of(_discoveredBleDevices));
      _setupConnectionListener(bleDevice.deviceId);
      _log.info("connected: ${_deviceNameCache[bleDevice.deviceId] ?? bleDevice.name ?? bleDevice.deviceId}");
    } catch (e, st) {
      _log.severe("connect error for ${bleDevice.deviceId}: $e", e, st);
    }
  }

  Future<void> _stopScanAndConnect() async {
    await UniversalBle.stopScan();
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    final pending = List.of(_pendingConnect);
    _pendingConnect.clear();
    _log.info("scan finished; connecting ${pending.length} device(s)");

    for (final bleDevice in pending) {
      if (!_platform.isWeb && _platform.isWindows) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      try {
        await UniversalBle.connect(bleDevice.deviceId);
        // Emit only after connection is established — DieDomain will then call
        // device.init() → discoverServices() on an already-connected device.
        _discoveredBleDevices[bleDevice.deviceId] =
            UniversalBleDevice(device: bleDevice, cachedName: _deviceNameCache[bleDevice.deviceId], platform: _platform);
        _bleDeviceSubscription.add(Map.of(_discoveredBleDevices));
        _setupConnectionListener(bleDevice.deviceId);
        _log.info("connected: ${_deviceNameCache[bleDevice.deviceId] ?? bleDevice.name ?? bleDevice.deviceId}");
      } catch (e, st) {
        _log.severe("connect error for ${bleDevice.deviceId}: $e", e, st);
      }
    }
  }

  void _setupConnectionListener(String deviceId) {
    _connectionSubscriptions[deviceId]?.cancel();
    _connectionSubscriptions[deviceId] =
        UniversalBle.connectionStream(deviceId).listen((bool isConnected) {
      if (!isConnected) {
        _log.warning("device disconnected: $deviceId");
        _discoveredBleDevices.remove(deviceId);
        _connectionSubscriptions[deviceId]?.cancel();
        _connectionSubscriptions.remove(deviceId);
        _bleDeviceSubscription.add(Map.of(_discoveredBleDevices));
      }
    });
  }

  @override
  Future<void> stopScan() async {
    if (await UniversalBle.isScanning()) await UniversalBle.stopScan();
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _pendingConnect.clear();
    _deviceLastSeen.clear();
  }

  @override
  Future<void> disconnectDevice(String deviceId) async {
    _connectionSubscriptions[deviceId]?.cancel();
    _connectionSubscriptions.remove(deviceId);
    _discoveredBleDevices.remove(deviceId);
    _bleDeviceSubscription.add(Map.of(_discoveredBleDevices));
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (e, st) {
      _log.warning('disconnect error for $deviceId: $e', e, st);
    }
  }

  @override
  Future<void> disconnectAllDevices() async {
    final ids = List.of(_discoveredBleDevices.keys);
    for (final deviceId in ids) {
      _connectionSubscriptions[deviceId]?.cancel();
      _connectionSubscriptions.remove(deviceId);
    }
    _discoveredBleDevices.clear();
    _bleDeviceSubscription.add(Map.of(_discoveredBleDevices));
    for (final deviceId in ids) {
      try {
        await UniversalBle.disconnect(deviceId);
      } catch (e, st) {
        _log.warning('disconnect error for $deviceId: $e', e, st);
      }
    }
  }

  @override
  void dispose() {
    stopScan();
    _adapterStateSubscription.cancel();
    for (final sub in _connectionSubscriptions.values) {
      sub.cancel();
    }
    _connectionSubscriptions.clear();
    _bleDeviceSubscription.close();
    _bleEnabledSubscription.close();
  }
}
