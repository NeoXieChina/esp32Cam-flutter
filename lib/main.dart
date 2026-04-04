import 'dart:async';
import 'dart:io'; // 引入 dart:io 用于判断平台
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
// ⬇️ 修改点 1: 导入新的库
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';

void main() {
  runApp(const MaterialApp(home: CameraApp()));
}

class CameraApp extends StatefulWidget {
  const CameraApp({super.key});

  @override
  State<CameraApp> createState() => _CameraAppState();
}

class _CameraAppState extends State<CameraApp> {
  final TextEditingController _ipController = TextEditingController(
    text: "192.168.4.1",
  );

  Uint8List? _imageBytes;
  bool _isRunning = false;
  String _status = "准备连接";

  Uint8List? _latestImageBytes;
  bool _shouldContinue = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  @override
  void dispose() {
    _shouldContinue = false;
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    // 桌面端不需要存储权限，只有移动端需要
    if (Platform.isAndroid || Platform.isIOS) {
      await [Permission.storage, Permission.photos].request();
    }
  }

  void _startPolling() {
    if (_ipController.text.isEmpty) return;
    setState(() {
      _isRunning = true;
      _status = "正在连接...";
      _shouldContinue = true;
    });
    _fetchNextFrame();
  }

  void _stopStream() {
    setState(() {
      _isRunning = false;
      _status = "已停止";
      _shouldContinue = false;
    });
  }

  Future<void> _fetchNextFrame() async {
    if (!_shouldContinue || !mounted) return;
    try {
      final url = Uri.http(_ipController.text, '/cam-hi.jpg', {
        't': DateTime.now().millisecondsSinceEpoch.toString(),
      });
      final response = await http
          .get(url)
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _imageBytes = response.bodyBytes;
            _latestImageBytes = response.bodyBytes;
            _status = "流畅模式中";
          });
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _fetchNextFrame();
        });
      } else {
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) _fetchNextFrame();
      }
    } catch (e) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) _fetchNextFrame();
    }
  }

  // 📸 拍照保存逻辑（全平台适配）
  Future<void> _takePhoto() async {
    if (!mounted) return;
    if (_latestImageBytes == null) {
      _showMessage("暂无画面");
      return;
    }

    try {
      // 1. 桌面端逻辑：直接保存到当前运行目录
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final fileName =
            "ESP32_Capture_${DateTime.now().millisecondsSinceEpoch}.jpg";
        final file = File(fileName);
        await file.writeAsBytes(_latestImageBytes!);

        // 弹窗提示并预览
        _showMessage("✅ 已保存到当前文件夹: $fileName", isSuccess: true);
        return;
      }

      // 2. 移动端逻辑：保存到系统相册
      // ⬇️ 修改点 2: 使用新库的方法
      // 新版本 saveImage 返回的是文件路径字符串 (String?)，失败返回 null
      final resultPath = await ImageGallerySaverPlus.saveImage(
        _latestImageBytes!,
        quality: 100,
        name: "ESP32_Capture_${DateTime.now().millisecondsSinceEpoch}",
      );

      // ⬇️ 修改点 3: 判断逻辑修改
      // 只要返回的路径不为空，就说明保存成功了
      if (resultPath != null && resultPath.isNotEmpty) {
        _showMessage("✅ 已保存到系统相册", isSuccess: true);
      } else {
        _showMessage("❌ 保存失败，请检查权限");
      }
    } catch (e) {
      _showMessage("❌ 异常: $e");
    }
  }

  void _showMessage(String msg, {bool isSuccess = false}) {
    if (!mounted) return;
    // 简单的弹窗提示，同时显示图片预览
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isSuccess ? "保存成功" : "提示"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_latestImageBytes != null)
              Container(
                height: 200,
                width: 300,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                ),
                child: Image.memory(_latestImageBytes!, fit: BoxFit.contain),
              ),
            const SizedBox(height: 10),
            Text(msg),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("关闭"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("ESP32 全平台监控版")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ipController,
                    decoration: const InputDecoration(labelText: "IP 地址"),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _isRunning ? _stopStream : _startPolling,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRunning ? Colors.red : Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(_isRunning ? "停止" : "开始"),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(_status),
            const SizedBox(height: 20),
            Expanded(
              child: GestureDetector(
                onTap: _takePhoto,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _imageBytes == null
                      ? const Center(child: Text("点击“开始”查看画面"))
                      : Image.memory(
                          _imageBytes!,
                          fit: BoxFit.contain,
                          cacheWidth: 640,
                          cacheHeight: 480,
                          gaplessPlayback: true,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _takePhoto,
                icon: const Icon(Icons.camera_alt),
                label: const Text("拍照保存"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
