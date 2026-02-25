import 'dart:async';
import 'dart:io';

import 'package:bluetooth_classic/models/device.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/bluetooth_service.dart';

class ConnectDeviceScreen extends StatefulWidget {
  final BluetoothService bluetoothService;
  final ValueChanged<Device>? onConnected;

  const ConnectDeviceScreen({
    super.key,
    required this.bluetoothService,
    this.onConnected,
  });

  @override
  State<ConnectDeviceScreen> createState() => _ConnectDeviceScreenState();
}

class _ConnectDeviceScreenState extends State<ConnectDeviceScreen> {
  final List<Device> _devices = <Device>[];
  StreamSubscription<Device>? _discoverySubscription;

  bool _isReady = false;
  bool _isScanning = false;
  bool _loading = true;
  String? _connectingAddress;
  String _statusText = "Checking Bluetooth permissions...";

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _discoverySubscription?.cancel();
    widget.bluetoothService.stopScan();
    super.dispose();
  }

  Future<void> _initialize() async {
    final granted = await _requestPermissions();
    final initialized = granted && await widget.bluetoothService.initialize();
    if (!mounted) {
      return;
    }

    if (!initialized) {
      setState(() {
        _loading = false;
        _isReady = false;
        _statusText =
            "Bluetooth permission denied. Pair in Android Settings first.";
      });
      return;
    }

    try {
      _discoverySubscription = widget.bluetoothService
          .onDeviceDiscovered()
          .listen(_addOrUpdateDevice, onError: (_) {});
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _isReady = false;
          _statusText =
              "Bluetooth discovery stream error. Reopen this screen and try again.";
        });
      }
      return;
    }
    await _refreshPairedDevices();

    if (!mounted) {
      return;
    }
    setState(() {
      _isReady = true;
      _loading = false;
      _statusText = "Bluetooth ready. Tap SCAN to discover nearby devices.";
    });
  }

  Future<void> _refreshPairedDevices() async {
    final paired = await widget.bluetoothService.getPairedDevices();
    for (final device in paired) {
      _addOrUpdateDevice(device);
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid) {
      return false;
    }

    final statuses = await <Permission>[
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.locationWhenInUse,
    ].request();

    final scan = statuses[Permission.bluetoothScan];
    final connect = statuses[Permission.bluetoothConnect];
    final location = statuses[Permission.locationWhenInUse];

    final modernBluetoothGranted =
        (scan == null || scan.isGranted || scan.isLimited) &&
        (connect == null || connect.isGranted || connect.isLimited);
    final legacyGranted =
        location?.isGranted == true || location?.isLimited == true;

    return modernBluetoothGranted || legacyGranted;
  }

  Future<void> _toggleScan() async {
    if (!_isReady) {
      return;
    }

    if (_isScanning) {
      await widget.bluetoothService.stopScan();
      if (!mounted) {
        return;
      }
      setState(() {
        _isScanning = false;
        _statusText = "Scan stopped.";
      });
      return;
    }

    final started = await widget.bluetoothService.startScan();
    if (!mounted) {
      return;
    }
    setState(() {
      _isScanning = started;
      _statusText = started
          ? "Scanning for devices..."
          : "Scan failed. Try pairing from Android Settings first.";
    });
  }

  Future<void> _connectToDevice(Device device) async {
    setState(() {
      _connectingAddress = device.address;
      _statusText = "Connecting to ${_displayName(device)}...";
    });

    await widget.bluetoothService.stopScan();
    final connected = await widget.bluetoothService.connect(device.address);
    if (!mounted) {
      return;
    }

    if (connected) {
      setState(() {
        _connectingAddress = null;
        _isScanning = false;
        _statusText = "Connected to ${_displayName(device)}.";
      });
      widget.onConnected?.call(device);
      if (widget.onConnected == null && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(device);
      }
      return;
    }

    setState(() {
      _connectingAddress = null;
      _statusText =
          "Connection failed. Pair in Android Settings and try again.";
    });
  }

  void _addOrUpdateDevice(Device device) {
    final index = _devices.indexWhere((item) => item.address == device.address);
    if (index >= 0) {
      _devices[index] = device;
    } else {
      _devices.add(device);
    }

    _devices.sort((a, b) => _displayName(a).compareTo(_displayName(b)));
    if (mounted) {
      setState(() {});
    }
  }

  String _displayName(Device device) {
    final name = (device.name ?? "").trim();
    if (name.isNotEmpty) {
      return name;
    }
    return device.address;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Connect Device")),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4F0DD),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _statusText,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF0F5132),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _toggleScan,
                          child: Text(_isScanning ? "STOP SCAN" : "SCAN"),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _refreshPairedDevices,
                          child: const Text("LOAD PAIRED"),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "Available devices",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _devices.isEmpty
                        ? const Center(
                            child: Text(
                              "No devices found.\n"
                              "Tip: Pair in Android Settings first.",
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.builder(
                            itemCount: _devices.length,
                            itemBuilder: (context, index) {
                              final device = _devices[index];
                              final connecting =
                                  _connectingAddress == device.address;

                              return Card(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                child: ListTile(
                                  title: Text(_displayName(device)),
                                  subtitle: Text(device.address),
                                  trailing: connecting
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : ElevatedButton(
                                          onPressed: () =>
                                              _connectToDevice(device),
                                          child: const Text("CONNECT"),
                                        ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}
