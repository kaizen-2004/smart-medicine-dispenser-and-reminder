import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/models/device.dart';

typedef LineMatcher = bool Function(String line);

class _PendingCommandResponse {
  final Completer<String?> completer;
  final LineMatcher matcher;

  _PendingCommandResponse({required this.completer, required this.matcher});

  void maybeComplete(String line) {
    if (completer.isCompleted) {
      return;
    }
    if (matcher(line)) {
      completer.complete(line);
    }
  }
}

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
  Future<void> _commandQueue = Future<void>.value();
  _PendingCommandResponse? _pendingResponse;

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
    final targetAddress = address.trim();
    if (targetAddress.isEmpty) {
      return false;
    }
    try {
      _bindListeners();
      _lastAddress = targetAddress;
      return await _classic
          .connect(targetAddress, serialPortUuid)
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
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
    LineMatcher? acceptResponse,
  }) async {
    return _enqueueCommand(() async {
      final matcher = acceptResponse ?? _defaultResponseMatcher;
      final response = await _sendAndAwait(
        command,
        timeout: timeout,
        matcher: matcher,
      );
      if (response != null || !retryOnNoResponse) {
        return response;
      }

      // Retry once without reconnect if link still appears active.
      if (isConnected) {
        return _sendAndAwait(command, timeout: timeout, matcher: matcher);
      }

      // Retry once on transient disconnect by reconnecting to last address.
      if (_lastAddress == null) {
        return null;
      }
      final reconnected = await connect(_lastAddress!);
      if (!reconnected) {
        return null;
      }
      return _sendAndAwait(command, timeout: timeout, matcher: matcher);
    });
  }

  bool _defaultResponseMatcher(String line) {
    return !line.startsWith("EVT,");
  }

  Future<T> _enqueueCommand<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _commandQueue = _commandQueue.then((_) async {
      try {
        final result = await action();
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }

  Future<String?> _sendAndAwait(
    String command, {
    required Duration timeout,
    required LineMatcher matcher,
  }) async {
    final pending = _PendingCommandResponse(
      completer: Completer<String?>(),
      matcher: matcher,
    );
    _pendingResponse = pending;

    try {
      final sent = await sendLine(command);
      if (!sent) {
        return null;
      }
      return pending.completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      if (identical(_pendingResponse, pending)) {
        _pendingResponse = null;
      }
    }
  }

  void _bindListeners() {
    _dataSubscription ??= _classic.onDeviceDataReceived().listen(
      _onData,
      onError: (_) {},
    );

    _statusSubscription ??= _classic.onDeviceStatusChanged().listen((status) {
      _lastStatus = status;
      if (status != Device.connected) {
        _failPendingCommand();
      }
      _statusController.add(status);
    }, onError: (_) {});
  }

  void _failPendingCommand() {
    final pending = _pendingResponse;
    if (pending == null) {
      return;
    }
    if (!pending.completer.isCompleted) {
      pending.completer.complete(null);
    }
    _pendingResponse = null;
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
        _pendingResponse?.maybeComplete(line);
      }
    }
  }

  void dispose() {
    _failPendingCommand();
    _dataSubscription?.cancel();
    _statusSubscription?.cancel();
    _lineController.close();
    _statusController.close();
  }
}
