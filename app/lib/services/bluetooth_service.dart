import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/models/device.dart';

class BluetoothService {
  static const String deviceName = "Smart-Medicine-Reminder";
  static const String serialPortUuid = "00001101-0000-1000-8000-00805f9b34fb";

  final BluetoothClassic _classic = BluetoothClassic();
  final StreamController<String> _lineController =
      StreamController<String>.broadcast();
  final StreamController<int> _statusController =
      StreamController<int>.broadcast();

  StreamSubscription<Uint8List>? _dataSubscription;
  StreamSubscription<int>? _statusSubscription;
  Stream<Device>? _deviceDiscoveryStream;
  String _buffer = "";
  int _lastStatus = Device.disconnected;
  String? _lastAddress;

  Stream<String> get onLineReceived => _lineController.stream;
  Stream<int> get onDeviceStatusChanged => _statusController.stream;
  bool get isConnected => _lastStatus == Device.connected;
  String? get lastAddress => _lastAddress;

  Future<bool> initialize() async {
    try {
      final permissionsGranted = await _classic.initPermissions();
      _bindListeners();
      return permissionsGranted;
    } catch (_) {
      return false;
    }
  }

  Future<List<Device>> getPairedDevices() async {
    try {
      return await _classic.getPairedDevices();
    } catch (_) {
      return <Device>[];
    }
  }

  Stream<Device> onDeviceDiscovered() {
    _deviceDiscoveryStream ??= _classic
        .onDeviceDiscovered()
        .asBroadcastStream();
    return _deviceDiscoveryStream!;
  }

  Future<bool> startScan() async {
    try {
      return await _classic.startScan();
    } catch (_) {
      return false;
    }
  }

  Future<bool> stopScan() async {
    try {
      return await _classic.stopScan();
    } catch (_) {
      return false;
    }
  }

  Future<bool> connect(String address) async {
    try {
      _bindListeners();
      _lastAddress = address;
      return await _classic.connect(address, serialPortUuid);
    } catch (_) {
      return false;
    }
  }

  Future<bool> disconnect() async {
    try {
      return await _classic.disconnect();
    } catch (_) {
      return false;
    }
  }

  Future<bool> sendLine(String message) async {
    final payload = message.endsWith("\n") ? message : "$message\n";
    try {
      return await _classic.write(payload);
    } catch (_) {
      return false;
    }
  }

  Future<String?> sendCommandExpectingLine(
    String command, {
    Duration timeout = const Duration(seconds: 8),
    bool retryOnNoResponse = true,
  }) async {
    final response = await _sendAndAwait(command, timeout: timeout);
    if (response != null || !retryOnNoResponse) {
      return response;
    }

    // Retry once without reconnect if link still appears active.
    if (isConnected) {
      return _sendAndAwait(command, timeout: timeout);
    }

    // Retry once on transient disconnect by reconnecting to last address.
    if (_lastAddress == null) {
      return null;
    }
    final reconnected = await connect(_lastAddress!);
    if (!reconnected) {
      return null;
    }
    return _sendAndAwait(command, timeout: timeout);
  }

  Future<String?> _sendAndAwait(
    String command, {
    required Duration timeout,
  }) async {
    final completer = Completer<String?>();
    late final StreamSubscription<String> sub;
    sub = onLineReceived.listen(
      (line) {
        if (line.startsWith("EVT,")) {
          // Keep waiting for command response while events are handled by
          // background listeners.
          return;
        }
        if (!completer.isCompleted) {
          completer.complete(line);
        }
      },
      onError: (_) {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      },
    );

    try {
      final sent = await sendLine(command);
      if (!sent) {
        return null;
      }
      return completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
    }
  }

  void _bindListeners() {
    _dataSubscription ??= _classic.onDeviceDataReceived().listen(
      _onData,
      onError: (_) {},
    );

    _statusSubscription ??= _classic.onDeviceStatusChanged().listen((status) {
      _lastStatus = status;
      _statusController.add(status);
    }, onError: (_) {});
  }

  void _onData(Uint8List data) {
    _buffer += utf8.decode(data, allowMalformed: true);
    while (true) {
      final newlineIndex = _buffer.indexOf("\n");
      if (newlineIndex < 0) {
        break;
      }
      final line = _buffer.substring(0, newlineIndex).trim();
      _buffer = _buffer.substring(newlineIndex + 1);
      if (line.isNotEmpty) {
        _lineController.add(line);
      }
    }
  }

  void dispose() {
    _dataSubscription?.cancel();
    _statusSubscription?.cancel();
    _lineController.close();
    _statusController.close();
  }
}
