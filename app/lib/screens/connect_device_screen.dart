import 'dart:async';
import 'dart:io';

import 'package:bluetooth_classic/models/device.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/bluetooth_service.dart';

enum _StatusTone { info, success, warning, error }

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
  static const String _associatedAddressKey = "associated_bt_device_address";

  final List<Device> _devices = <Device>[];
  final Map<String, DateTime> _discoveredAt = <String, DateTime>{};
  StreamSubscription<Device>? _discoverySubscription;
  StreamSubscription<int>? _statusSubscription;

  bool _isReady = false;
  bool _isScanning = false;
  bool _loading = true;
  String? _connectingAddress;
  String? _associatedAddress;
  String _statusText = "Checking Bluetooth permissions...";
  _StatusTone _statusTone = _StatusTone.info;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _discoverySubscription?.cancel();
    _statusSubscription?.cancel();
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
        _statusTone = _StatusTone.error;
        _statusText =
            "Bluetooth permission is required to connect the pillbox.";
      });
      return;
    }

    await _loadAssociatedAddress();

    try {
      _discoverySubscription = widget.bluetoothService
          .onDeviceDiscovered()
          .listen(
            (device) => _addOrUpdateDevice(device, markDiscoveredNow: true),
            onError: (_) {},
          );
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _isReady = false;
          _statusTone = _StatusTone.error;
          _statusText =
              "Bluetooth scan is unavailable right now. Reopen this screen and try again.";
        });
      }
      return;
    }
    _statusSubscription = widget.bluetoothService.onDeviceStatusChanged.listen((
      _,
    ) {
      if (!mounted) {
        return;
      }
      setState(() {});
    });
    await _refreshPairedDevices();

    if (!mounted) {
      return;
    }
    setState(() {
      _isReady = true;
      _loading = false;
      _statusTone = _StatusTone.info;
      _statusText = _associatedAddress == null
          ? "Scan to find your Smart Medicine Reminder device."
          : "Linked device loaded. Tap SCAN to check if it is online.";
    });
  }

  Future<void> _loadAssociatedAddress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _associatedAddress = prefs.getString(_associatedAddressKey);
    } catch (_) {
      _associatedAddress = null;
    }
  }

  Future<void> _saveAssociatedAddress(String address) async {
    _associatedAddress = address;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_associatedAddressKey, address);
    } catch (_) {}
  }

  Future<void> _clearAssociatedAddress() async {
    _associatedAddress = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_associatedAddressKey);
    } catch (_) {}
  }

  Future<void> _refreshPairedDevices() async {
    final paired = await widget.bluetoothService.getPairedDevices();
    for (final device in paired) {
      _addOrUpdateDevice(device);
    }
    if (mounted) {
      setState(() {
        if (_visibleDevices.isEmpty && _associatedAddress != null) {
          _statusTone = _StatusTone.warning;
          _statusText =
              "Linked device is offline. Turn on the device and scan.";
        }
      });
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
        _statusTone = _StatusTone.info;
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
      _statusTone = started ? _StatusTone.info : _StatusTone.error;
      _statusText = started
          ? "Scanning for your Smart Medicine Reminder..."
          : "Scan failed. Enable Bluetooth and try again.";
    });
  }

  Future<void> _connectToDevice(Device device) async {
    if (_connectingAddress != null) {
      return;
    }

    final connectedToSameDevice =
        widget.bluetoothService.isConnected &&
        widget.bluetoothService.lastAddress == device.address;
    if (!connectedToSameDevice && !_wasDiscoveredRecently(device.address)) {
      setState(() {
        _statusTone = _StatusTone.warning;
        _statusText =
            "Device is offline. Turn on the pillbox, tap SCAN, then CONNECT.";
      });
      return;
    }

    setState(() {
      _connectingAddress = device.address;
      _statusTone = _StatusTone.info;
      _statusText = "Connecting to ${_displayName(device)}...";
    });

    try {
      await widget.bluetoothService.stopScan();
      final connected = await widget.bluetoothService
          .connect(device.address)
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
      if (!mounted) {
        return;
      }

      if (connected) {
        await _saveAssociatedAddress(device.address);
        setState(() {
          _connectingAddress = null;
          _isScanning = false;
          _statusTone = _StatusTone.success;
          _statusText = "Connected to ${_displayName(device)}.";
        });
        widget.onConnected?.call(device);
        if (!mounted) {
          return;
        }
        final navigator = Navigator.of(context);
        if (widget.onConnected == null && navigator.canPop()) {
          navigator.pop(device);
        }
        return;
      }

      setState(() {
        _connectingAddress = null;
        _statusTone = _StatusTone.error;
        _statusText =
            "Connection failed. Keep the device near your phone and try again.";
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _connectingAddress = null;
        _statusTone = _StatusTone.error;
        _statusText =
            "Connection error. Device may be off. Turn it on and scan again.";
      });
    }
  }

  bool _wasDiscoveredRecently(String address) {
    final discoveredAt = _discoveredAt[address];
    if (discoveredAt == null) {
      return false;
    }
    return DateTime.now().difference(discoveredAt) <=
        const Duration(seconds: 30);
  }

  void _addOrUpdateDevice(Device device, {bool markDiscoveredNow = false}) {
    final index = _devices.indexWhere((item) => item.address == device.address);
    if (index >= 0) {
      _devices[index] = device;
    } else {
      _devices.add(device);
    }
    if (markDiscoveredNow) {
      _discoveredAt[device.address] = DateTime.now();
    }

    _devices.sort((a, b) => _displayName(a).compareTo(_displayName(b)));
    if (mounted) {
      setState(() {});
    }
  }

  String _normalizedName(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  bool _matchesProjectDeviceName(Device device) {
    final name = (device.name ?? "").trim();
    if (name.isEmpty) {
      return false;
    }
    return _normalizedName(name) ==
        _normalizedName(BluetoothService.deviceName);
  }

  bool _shouldShowDevice(Device device) {
    if (_associatedAddress != null && _associatedAddress!.isNotEmpty) {
      return device.address == _associatedAddress;
    }
    return _matchesProjectDeviceName(device);
  }

  List<Device> get _visibleDevices =>
      _devices.where(_shouldShowDevice).toList(growable: false);

  String _displayName(Device device) {
    final name = (device.name ?? "").trim();
    if (name.isNotEmpty) {
      return name;
    }
    return "Smart Medicine Reminder";
  }

  IconData _statusIcon() {
    switch (_statusTone) {
      case _StatusTone.success:
        return Icons.check_circle_rounded;
      case _StatusTone.warning:
        return Icons.warning_amber_rounded;
      case _StatusTone.error:
        return Icons.error_outline_rounded;
      case _StatusTone.info:
        return Icons.info_outline_rounded;
    }
  }

  Color _statusForeground() {
    switch (_statusTone) {
      case _StatusTone.success:
        return const Color(0xFF1B5E20);
      case _StatusTone.warning:
        return const Color(0xFF8D6E00);
      case _StatusTone.error:
        return const Color(0xFFB71C1C);
      case _StatusTone.info:
        return const Color(0xFF0D47A1);
    }
  }

  Color _statusBackground() {
    switch (_statusTone) {
      case _StatusTone.success:
        return const Color(0xFFE8F5E9);
      case _StatusTone.warning:
        return const Color(0xFFFFF8E1);
      case _StatusTone.error:
        return const Color(0xFFFFEBEE);
      case _StatusTone.info:
        return const Color(0xFFE3F2FD);
    }
  }

  Widget _buildIntroCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          colors: [Color(0xFF2E7D32), Color(0xFF3C9B41)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Container(
            height: 48,
            width: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.medication_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Smart Medicine Reminder",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  "Connect once to sync schedule and device time.",
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    final fg = _statusForeground();
    final bg = _statusBackground();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: fg.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_statusIcon(), color: fg, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _statusText,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLinkedDeviceCard() {
    final hasLinked =
        _associatedAddress != null && _associatedAddress!.isNotEmpty;
    final isConnected = widget.bluetoothService.isConnected && hasLinked;
    final statusText = hasLinked
        ? (isConnected ? "Connected" : "Saved device (currently offline)")
        : "No linked device yet";
    final statusColor = isConnected
        ? const Color(0xFF1B5E20)
        : const Color(0xFF455A64);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x1A000000)),
      ),
      child: Row(
        children: [
          const Icon(Icons.bluetooth_rounded, color: Color(0xFF2E7D32)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Linked Device",
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.black.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasLinked ? BluetoothService.deviceName : "Not linked",
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 12,
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (hasLinked)
            TextButton(
              onPressed: () async {
                await _clearAssociatedAddress();
                if (!mounted) {
                  return;
                }
                setState(() {
                  _statusTone = _StatusTone.info;
                  _statusText =
                      "Device link cleared. Scan to link Smart Medicine Reminder again.";
                });
              },
              child: const Text("Change"),
            ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    final visibleDevices = _visibleDevices;
    if (visibleDevices.isEmpty) {
      final hasLinked =
          _associatedAddress != null && _associatedAddress!.isNotEmpty;
      return Center(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0x1A000000)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasLinked
                    ? Icons.bluetooth_disabled_rounded
                    : Icons.bluetooth_searching_rounded,
                size: 34,
                color: const Color(0xFF2E7D32),
              ),
              const SizedBox(height: 10),
              Text(
                hasLinked
                    ? "Device is offline"
                    : "No Smart Medicine Reminder found",
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                hasLinked
                    ? "Turn on your pillbox, keep it near the phone, then tap SCAN."
                    : "Pair the pillbox once in Android Bluetooth settings, then tap SCAN.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.black.withValues(alpha: 0.65),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: visibleDevices.length,
      itemBuilder: (context, index) {
        final device = visibleDevices[index];
        final connecting = _connectingAddress == device.address;
        final connectedToSameDevice =
            widget.bluetoothService.isConnected &&
            widget.bluetoothService.lastAddress == device.address;
        final discoveredRecently = _wasDiscoveredRecently(device.address);
        final isOffline = !connectedToSameDevice && !discoveredRecently;

        final statusLabel = connectedToSameDevice
            ? "Connected"
            : discoveredRecently
            ? "Online"
            : "Offline";
        final statusColor = connectedToSameDevice
            ? const Color(0xFF1B5E20)
            : discoveredRecently
            ? const Color(0xFF1565C0)
            : const Color(0xFFB71C1C);

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: connectedToSameDevice
                  ? const Color(0x553C9B41)
                  : const Color(0x1A000000),
            ),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            leading: Container(
              height: 38,
              width: 38,
              decoration: BoxDecoration(
                color: const Color(0x1A2E7D32),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.bluetooth_rounded,
                color: Color(0xFF2E7D32),
              ),
            ),
            title: Text(
              _displayName(device),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            trailing: connecting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  )
                : ElevatedButton(
                    onPressed: isOffline
                        ? null
                        : () => _connectToDevice(device),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0x1A2E7D32),
                      disabledForegroundColor: const Color(0x802E7D32),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Text(
                      "CONNECT",
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Connect Device"),
        centerTitle: true,
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFEAF7EE), Color(0xFFF5FBF7)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF2E7D32)),
              )
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildIntroCard(),
                      const SizedBox(height: 10),
                      _buildStatusBanner(),
                      const SizedBox(height: 10),
                      _buildLinkedDeviceCard(),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _toggleScan,
                              icon: Icon(
                                _isScanning
                                    ? Icons.stop_circle_outlined
                                    : Icons.radar_rounded,
                              ),
                              label: Text(_isScanning ? "STOP SCAN" : "SCAN"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2E7D32),
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(46),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _refreshPairedDevices,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text("REFRESH"),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF2E7D32),
                                side: const BorderSide(
                                  color: Color(0x662E7D32),
                                ),
                                minimumSize: const Size.fromHeight(46),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "Available Device",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Colors.black.withValues(alpha: 0.75),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(child: _buildDeviceList()),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
