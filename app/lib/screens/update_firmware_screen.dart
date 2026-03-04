import 'dart:async';

import 'package:bluetooth_classic/models/device.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/bluetooth_service.dart';

enum _UpdateTone { info, success, warning, error }

class UpdateFirmwareScreen extends StatefulWidget {
  final BluetoothService bluetoothService;

  const UpdateFirmwareScreen({super.key, required this.bluetoothService});

  @override
  State<UpdateFirmwareScreen> createState() => _UpdateFirmwareScreenState();
}

class _UpdateFirmwareScreenState extends State<UpdateFirmwareScreen> {
  static const MethodChannel _platformChannel = MethodChannel("smr/platform");

  StreamSubscription<int>? _statusSubscription;
  StreamSubscription<String>? _lineSubscription;
  Timer? _countdownTimer;

  bool _isConnected = false;
  bool _busy = false;
  _UpdateTone _tone = _UpdateTone.info;
  String _message =
      "Connect your Smart Medicine Reminder device, then tap ENTER UPDATE MODE.";

  bool _otaOn = false;
  String? _ssid;
  String? _wifiPassword;
  String? _ip;
  String? _url;
  String? _webUser;
  String? _webPassword;
  DateTime? _expiresAt;

  @override
  void initState() {
    super.initState();
    _isConnected = widget.bluetoothService.isConnected;
    _statusSubscription = widget.bluetoothService.onDeviceStatusChanged.listen((
      status,
    ) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isConnected = status == Device.connected;
      });
    });

    _lineSubscription = widget.bluetoothService.onLineReceived.listen((line) {
      _handleProtocolLine(line.trim());
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _expiresAt == null) {
        return;
      }
      if (_expiresAt!.isBefore(DateTime.now())) {
        setState(() {
          _expiresAt = null;
        });
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _lineSubscription?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _setMessage(_UpdateTone tone, String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _tone = tone;
      _message = message;
    });
  }

  Map<String, String> _parseKeyValues(List<String> parts, int startIndex) {
    final map = <String, String>{};
    for (var i = startIndex; (i + 1) < parts.length; i += 2) {
      final key = parts[i].trim().toUpperCase();
      final value = parts[i + 1].trim();
      if (key.isNotEmpty) {
        map[key] = value;
      }
    }
    return map;
  }

  void _applyOtaMap(Map<String, String> map, {required bool on}) {
    if (!mounted) {
      return;
    }
    if (!on) {
      setState(() {
        _otaOn = false;
        _expiresAt = null;
      });
      return;
    }

    final timeoutSec = int.tryParse(map["TIMEOUT_S"] ?? "");
    final ip = map["IP"] ?? _ip;
    final derivedUrl = ip == null ? null : "http://$ip/update";

    setState(() {
      _otaOn = true;
      _ssid = map["SSID"] ?? _ssid;
      _wifiPassword = map["PASS"] ?? _wifiPassword;
      _ip = ip;
      _url = map["URL"] ?? _url ?? derivedUrl;
      _webUser = map["USER"] ?? _webUser;
      _webPassword = map["HTTP_PASS"] ?? _webPassword;
      if (timeoutSec != null && timeoutSec > 0) {
        _expiresAt = DateTime.now().add(Duration(seconds: timeoutSec));
      }
    });
  }

  void _handleProtocolLine(String line) {
    if (line.isEmpty) {
      return;
    }

    if (line.startsWith("AP_READY,")) {
      final parts = line.split(",");
      final map = _parseKeyValues(parts, 1);
      _applyOtaMap(map, on: true);
      _setMessage(
        _UpdateTone.success,
        "Update mode is ready. Follow the steps below.",
      );
      return;
    }

    if (line.startsWith("OTA_STATUS,")) {
      final parts = line.split(",");
      if (parts.length >= 2 && parts[1].toUpperCase() == "OFF") {
        _applyOtaMap(const <String, String>{}, on: false);
        _setMessage(_UpdateTone.info, "Update mode is currently OFF.");
        return;
      }
      if (parts.length >= 2 && parts[1].toUpperCase() == "ON") {
        final map = _parseKeyValues(parts, 2);
        _applyOtaMap(map, on: true);
        _setMessage(
          _UpdateTone.success,
          "Update mode is ON. Connect to device Wi-Fi and upload firmware.",
        );
      }
      return;
    }

    if (line == "EVT,UPDATE_TIMEOUT") {
      _applyOtaMap(const <String, String>{}, on: false);
      _setMessage(
        _UpdateTone.warning,
        "Update mode timed out. Tap ENTER UPDATE MODE again.",
      );
      return;
    }

    if (line == "OK,UPDATE_MODE_OFF") {
      _applyOtaMap(const <String, String>{}, on: false);
      _setMessage(_UpdateTone.info, "Update mode turned off.");
      return;
    }
  }

  bool _otaCommandMatcher(String command, String line) {
    if (line.startsWith("ERR,")) {
      return true;
    }

    switch (command) {
      case "ENTER_UPDATE_MODE":
        return line == "OK,UPDATE_MODE_ON" ||
            line.startsWith("AP_READY,") ||
            line.startsWith("OTA_STATUS,");
      case "OTA_STATUS":
        return line.startsWith("OTA_STATUS,");
      case "EXIT_UPDATE_MODE":
        return line == "OK,UPDATE_MODE_OFF";
      default:
        return !line.startsWith("EVT,");
    }
  }

  Future<void> _runCommand(
    String command, {
    required String waitingMessage,
    required String noResponseMessage,
  }) async {
    if (!_isConnected) {
      _setMessage(
        _UpdateTone.warning,
        "Device is offline. Go to Connect tab and connect first.",
      );
      return;
    }
    if (_busy) {
      return;
    }

    setState(() {
      _busy = true;
    });
    _setMessage(_UpdateTone.info, waitingMessage);

    try {
      final response = await widget.bluetoothService.sendCommandExpectingLine(
        command,
        timeout: const Duration(seconds: 8),
        retryOnNoResponse: false,
        acceptResponse: (line) => _otaCommandMatcher(command, line),
      );
      if (response == null) {
        _setMessage(_UpdateTone.error, noResponseMessage);
        return;
      }

      if (response.startsWith("ERR,")) {
        _setMessage(_UpdateTone.error, "Device error: $response");
        return;
      }

      _handleProtocolLine(response);
      if (command == "ENTER_UPDATE_MODE") {
        final statusResponse = await widget.bluetoothService
            .sendCommandExpectingLine(
              "OTA_STATUS",
              timeout: const Duration(seconds: 6),
              retryOnNoResponse: false,
              acceptResponse: (line) => _otaCommandMatcher("OTA_STATUS", line),
            );
        if (statusResponse != null && statusResponse.isNotEmpty) {
          _handleProtocolLine(statusResponse);
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _openUpdateUrl() async {
    final urlText = _url;
    if (urlText == null || urlText.isEmpty) {
      _setMessage(
        _UpdateTone.warning,
        "Update URL is not available yet. Enter update mode first.",
      );
      return;
    }

    final opened = await _openUrlWithPlatform(urlText);
    if (!opened) {
      _setMessage(
        _UpdateTone.error,
        "Could not open browser. Open this URL manually: $urlText",
      );
    }
  }

  Future<void> _openUrlText(String urlText) async {
    final opened = await _openUrlWithPlatform(urlText);
    if (!opened) {
      _setMessage(
        _UpdateTone.error,
        "Could not open browser. Open this URL manually: $urlText",
      );
    }
  }

  Future<bool> _openUrlWithPlatform(String urlText) async {
    final uri = Uri.tryParse(urlText);
    if (uri == null || (!uri.hasScheme && !urlText.startsWith("http://"))) {
      _setMessage(_UpdateTone.error, "Invalid update URL.");
      return false;
    }
    try {
      final result = await _platformChannel.invokeMethod<bool>(
        "openExternalUrl",
        <String, dynamic>{"url": urlText},
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _copyValue(String label, String? value) async {
    if (value == null || value.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text("$label copied")));
  }

  Color _toneBg(_UpdateTone tone) {
    switch (tone) {
      case _UpdateTone.success:
        return const Color(0xFFE8F5E9);
      case _UpdateTone.warning:
        return const Color(0xFFFFF8E1);
      case _UpdateTone.error:
        return const Color(0xFFFFEBEE);
      case _UpdateTone.info:
        return const Color(0xFFE3F2FD);
    }
  }

  Color _toneFg(_UpdateTone tone) {
    switch (tone) {
      case _UpdateTone.success:
        return const Color(0xFF1B5E20);
      case _UpdateTone.warning:
        return const Color(0xFF8D6E00);
      case _UpdateTone.error:
        return const Color(0xFFB71C1C);
      case _UpdateTone.info:
        return const Color(0xFF0D47A1);
    }
  }

  IconData _toneIcon(_UpdateTone tone) {
    switch (tone) {
      case _UpdateTone.success:
        return Icons.check_circle_rounded;
      case _UpdateTone.warning:
        return Icons.warning_amber_rounded;
      case _UpdateTone.error:
        return Icons.error_outline_rounded;
      case _UpdateTone.info:
        return Icons.info_outline_rounded;
    }
  }

  String _countdownText() {
    if (_expiresAt == null) {
      return "Not started";
    }
    final remaining = _expiresAt!.difference(DateTime.now());
    if (remaining.isNegative) {
      return "Expired";
    }
    final totalSeconds = remaining.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return "${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}";
  }

  Widget _detailRow(
    String label,
    String? value, {
    bool canCopy = true,
    bool emphasize = false,
  }) {
    final text = value == null || value.isEmpty ? "-" : value;
    final isUrl = label.toUpperCase() == "URL" && text != "-";
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: isUrl ? () => _openUrlText(text) : null,
              child: Text(
                text,
                style: TextStyle(
                  fontSize: emphasize ? 14 : 13,
                  fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
                  color: isUrl
                      ? const Color(0xFF1565C0)
                      : const Color(0xFF1F4F37),
                  decoration: isUrl ? TextDecoration.underline : null,
                ),
              ),
            ),
          ),
          if (canCopy && text != "-")
            IconButton(
              icon: const Icon(Icons.copy_rounded, size: 18),
              tooltip: "Copy $label",
              color: const Color(0xFF2E7D32),
              onPressed: () => _copyValue(label, value),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _buildEmergencyHelpCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.support_agent_rounded,
                color: Color(0xFF2E7D32),
                size: 20,
              ),
              SizedBox(width: 8),
              Text(
                "Emergency Help",
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1F4F37),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text("If update page does not open:"),
          SizedBox(height: 4),
          Text("1. Make sure phone is connected to the device Wi-Fi SSID."),
          SizedBox(height: 2),
          Text("2. Keep mobile data off temporarily while updating."),
          SizedBox(height: 2),
          Text("3. Tap OPEN UPDATE PAGE again."),
          SizedBox(height: 8),
          Text("If upload fails:"),
          SizedBox(height: 4),
          Text("1. Keep device powered by USB and close to the phone."),
          SizedBox(height: 2),
          Text("2. Re-enter update mode and upload the file again."),
          SizedBox(height: 2),
          Text("3. If still failing, ask caregiver/technician for help."),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final toneFg = _toneFg(_tone);
    final toneBg = _toneBg(_tone);
    final connectedText = _isConnected ? "Connected" : "Not connected";
    final connectedColor = _isConnected
        ? const Color(0xFF1B5E20)
        : const Color(0xFFB71C1C);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Update Firmware"),
        centerTitle: true,
        backgroundColor: const Color(0xFF2E7D32),
        foregroundColor: Colors.white,
      ),
      body: Container(
        color: const Color(0xFFEAF7EE),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2E7D32), Color(0xFF3A9B43)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.system_update_alt_rounded, color: Colors.white),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Update your device firmware from phone browser using the built-in update page.",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isConnected
                          ? Icons.bluetooth_connected_rounded
                          : Icons.bluetooth_disabled_rounded,
                      color: connectedColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Device: $connectedText",
                        style: TextStyle(
                          color: connectedColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: toneBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: toneFg.withValues(alpha: 0.2)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_toneIcon(_tone), color: toneFg),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _message,
                        style: TextStyle(
                          color: toneFg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _runCommand(
                        "ENTER_UPDATE_MODE",
                        waitingMessage: "Requesting update mode...",
                        noResponseMessage:
                            "No response from device. Keep it connected and try again.",
                      ),
                icon: _busy
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded),
                label: const Text(
                  "ENTER UPDATE MODE",
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _runCommand(
                              "OTA_STATUS",
                              waitingMessage: "Checking update status...",
                              noResponseMessage:
                                  "No status response from device.",
                            ),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text("CHECK STATUS"),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _runCommand(
                              "EXIT_UPDATE_MODE",
                              waitingMessage: "Turning update mode off...",
                              noResponseMessage:
                                  "No response while exiting update mode.",
                            ),
                      icon: const Icon(Icons.power_settings_new_rounded),
                      label: const Text("EXIT MODE"),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Update Session",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F4F37),
                      ),
                    ),
                    const SizedBox(height: 6),
                    _detailRow("Mode", _otaOn ? "ON" : "OFF", canCopy: false),
                    _detailRow("SSID", _ssid),
                    _detailRow("Wi-Fi Pass", _wifiPassword),
                    _detailRow("Web User", _webUser),
                    _detailRow("Web Pass", _webPassword),
                    _detailRow("IP", _ip),
                    _detailRow("URL", _url, emphasize: true),
                    _detailRow(
                      "Time Left",
                      _countdownText(),
                      canCopy: false,
                      emphasize: true,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _openUpdateUrl,
                        icon: const Icon(Icons.open_in_browser_rounded),
                        label: const Text("OPEN UPDATE PAGE"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Simple Steps",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F4F37),
                      ),
                    ),
                    SizedBox(height: 8),
                    Text("1. Tap ENTER UPDATE MODE."),
                    SizedBox(height: 4),
                    Text("2. Open phone Wi-Fi and connect to the shown SSID."),
                    SizedBox(height: 4),
                    Text("3. Tap OPEN UPDATE PAGE."),
                    SizedBox(height: 4),
                    Text("4. Login, then upload the firmware .bin file."),
                    SizedBox(height: 4),
                    Text("5. Wait for reboot, then reconnect in Connect tab."),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _buildEmergencyHelpCard(),
            ],
          ),
        ),
      ),
    );
  }
}
