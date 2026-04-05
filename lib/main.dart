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
  final TextEditingController _portController = TextEditingController(
    text: "80",
  );

  Uint8List? _imageBytes;
  bool _isRunning = false;
  String _status = "准备连接";
  
  Uint8List? _latestImageBytes;
  bool _shouldContinue = false;
  
  // 帧率统计
  int _frameCount = 0;
  DateTime? _startTime;
  double _fps = 0.0;
  
  // LED 控制
  int _ledIntensity = 0;
  
  // 摄像头设置状态
  final Map<String, dynamic> _cameraSettings = {
    'framesize': 7, // VGA
    'quality': 12,
    'brightness': 0,
    'contrast': 0,
    'saturation': 0,
    'sharpness': 0,
    'denoise': 4,
    'gainceiling': 0,
    'colorbar': 0,
    'awb': 1,
    'dcw': 1,
    'agc': 1,
    'aec': 1,
    'hmirror': 0,
    'vflip': 0,
    'aec2': 0,
    'awb_gain': 1,
    'agc_gain': 0,
    'aec_value': 204,
    'bpc': 0,
    'wpc': 1,
    'raw_gma': 1,
    'lenc': 1,
    'special_effect': 0,
    'wb_mode': 0,
    'ae_level': 0,
    'led_intensity': 0,
  };
  
  bool _isLoadingSettings = false;

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
      _frameCount = 0;
      _startTime = DateTime.now();
    });
    
    _fetchNextFrame();
  }

  void _stopStream() {
    setState(() {
      _isRunning = false;
      _status = "已停止";
      _shouldContinue = false;
      _fps = 0.0;
    });
  }

  // 发送控制命令到ESP32
  Future<void> _sendCommand(String variable, int value) async {
    try {
      final port = int.tryParse(_portController.text) ?? 80;
      final url = Uri.http(
        '${_ipController.text}:$port',
        '/control',
        {'var': variable, 'val': value.toString()},
      );
      
      final response = await http.get(url).timeout(const Duration(seconds: 2));
      
      if (response.statusCode == 200) {
        setState(() {
          _cameraSettings[variable] = value;
          // 特殊处理LED强度
          if (variable == 'led_intensity') {
            _ledIntensity = value;
          }
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已设置 $variable = $value'),
              duration: const Duration(seconds: 1),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('设置失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  // 获取当前摄像头状态
  Future<void> _loadCameraStatus() async {
    if (!_isRunning) return;
    
    setState(() {
      _isLoadingSettings = true;
    });
    
    try {
      final port = int.tryParse(_portController.text) ?? 80;
      final url = Uri.http('${_ipController.text}:$port', '/status');
      
      final response = await http.get(url).timeout(const Duration(seconds: 2));
      
      if (response.statusCode == 200) {
        // 这里可以解析JSON更新状态
        // print('状态加载成功');
      }
    } catch (e) {
      // print('加载状态失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingSettings = false;
        });
      }
    }
  }

  // JPEG 轮询模式
  Future<void> _fetchNextFrame() async {
    if (!_shouldContinue || !mounted) return;
    try {
      final port = int.tryParse(_portController.text) ?? 80;
      // ESP32-CAM 使用 /capture 端点获取单帧图片
      final url = Uri.http('${_ipController.text}:$port', '/capture', {
        '_cb': DateTime.now().millisecondsSinceEpoch.toString(),
      });
      final response = await http
          .get(url)
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _imageBytes = response.bodyBytes;
            _latestImageBytes = response.bodyBytes;
            _status = "JPEG 模式中";
            
            // 计算 FPS
            _frameCount++;
            if (_startTime != null) {
              final elapsed = DateTime.now().difference(_startTime!).inSeconds;
              if (elapsed > 0) {
                _fps = _frameCount / elapsed;
              }
            }
          });
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _fetchNextFrame();
        });
      } else {
        if (mounted) {
          setState(() {
            _status = "JPEG 错误: HTTP ${response.statusCode}";
          });
        }
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted && _shouldContinue) _fetchNextFrame();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = "连接错误: $e";
        });
      }
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted && _shouldContinue) _fetchNextFrame();
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
  
  // 显示设置面板
  void _showSettingsPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '摄像头设置',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(16),
                children: [
                  // LED 控制（放在最前面）
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: Colors.orange[50],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.flashlight_on, color: Colors.orange[700]),
                              const SizedBox(width: 8),
                              const Text(
                                'LED 闪光灯控制',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('亮度'),
                              Text(
                                '$_ledIntensity%',
                                style: const TextStyle(
                                  color: Colors.orange,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          Slider(
                            value: _ledIntensity.toDouble(),
                            min: 0,
                            max: 100,
                            divisions: 100,
                            activeColor: Colors.orange,
                            onChanged: (newValue) {
                              final intensity = newValue.round();
                              // ESP32的LED强度范围是0-255
                              final esp32Value = (intensity * 255 / 100).round();
                              _sendCommand('led_intensity', esp32Value);
                            },
                          ),
                          const Text(
                            '💡 提示：调节LED亮度可改善低光环境下的画面质量',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(thickness: 2),
                  
                  // 图像质量设置组
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '📷 图像质量',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey,
                      ),
                    ),
                  ),
                  _buildSliderSetting(
                    '分辨率',
                    'framesize',
                    _cameraSettings['framesize'],
                    0,
                    12,
                    ['QQVGA', 'QCIF', 'HQVGA', '240X240', 'QVGA', 'CIF', 'HVGA', 'VGA', 'SVGA', 'XGA', 'HD', 'SXGA', 'UXGA'],
                  ),
                  _buildSliderSetting('JPEG质量', 'quality', _cameraSettings['quality'], 0, 63, null, reverse: true, info: '数值越小质量越高'),
                  _buildSliderSetting('亮度', 'brightness', _cameraSettings['brightness'], -2, 2, null),
                  _buildSliderSetting('对比度', 'contrast', _cameraSettings['contrast'], -2, 2, null),
                  _buildSliderSetting('饱和度', 'saturation', _cameraSettings['saturation'], -2, 2, null),
                  
                  const Divider(),
                  
                  // 高级图像设置
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '🎨 高级图像',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey,
                      ),
                    ),
                  ),
                  _buildSliderSetting('锐度', 'sharpness', _cameraSettings['sharpness'], -2, 2, null),
                  _buildSliderSetting('降噪', 'denoise', _cameraSettings['denoise'], 0, 8, null, info: '高值可能降低帧率'),
                  _buildSliderSetting('增益上限', 'gainceiling', _cameraSettings['gainceiling'], 0, 6, 
                    ['x2', 'x4', 'x8', 'x16', 'x32', 'x64', 'x128']),
                  _buildSliderSetting('特效', 'special_effect', _cameraSettings['special_effect'], 0, 6, 
                    ['无', '负片', '灰度', '红色调', '绿色调', '蓝色调', '复古']),
                  _buildSliderSetting('白平衡模式', 'wb_mode', _cameraSettings['wb_mode'], 0, 4, 
                    ['自动', '阳光', '阴天', '办公室', '家庭']),
                  _buildSliderSetting('曝光等级', 'ae_level', _cameraSettings['ae_level'], -2, 2, null),
                  _buildSliderSetting('AEC值', 'aec_value', _cameraSettings['aec_value'], 0, 1200, null),
                  
                  const Divider(),
                  
                  // 自动控制开关
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '⚙️ 自动控制',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey,
                      ),
                    ),
                  ),
                  _buildSwitchSetting('自动白平衡 (AWB)', 'awb', _cameraSettings['awb']),
                  _buildSwitchSetting('AWB增益', 'awb_gain', _cameraSettings['awb_gain']),
                  _buildSwitchSetting('自动增益 (AGC)', 'agc', _cameraSettings['agc']),
                  _buildSliderSetting('AGC增益', 'agc_gain', _cameraSettings['agc_gain'], 0, 30, null),
                  _buildSwitchSetting('自动曝光 (AEC)', 'aec', _cameraSettings['aec']),
                  _buildSwitchSetting('AEC2 (DSP)', 'aec2', _cameraSettings['aec2']),
                  _buildSwitchSetting('DCW (下采样)', 'dcw', _cameraSettings['dcw']),
                  
                  const Divider(),
                  
                  // 图像处理开关
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '🔧 图像处理',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey,
                      ),
                    ),
                  ),
                  _buildSwitchSetting('坏点校正 (BPC)', 'bpc', _cameraSettings['bpc']),
                  _buildSwitchSetting('白点校正 (WPC)', 'wpc', _cameraSettings['wpc']),
                  _buildSwitchSetting('Raw Gamma', 'raw_gma', _cameraSettings['raw_gma']),
                  _buildSwitchSetting('镜头校正 (LENC)', 'lenc', _cameraSettings['lenc']),
                  
                  const Divider(),
                  
                  // 图像变换
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '🔄 图像变换',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey,
                      ),
                    ),
                  ),
                  _buildSwitchSetting('水平镜像', 'hmirror', _cameraSettings['hmirror']),
                  _buildSwitchSetting('垂直翻转', 'vflip', _cameraSettings['vflip']),
                  _buildSwitchSetting('色彩条测试', 'colorbar', _cameraSettings['colorbar']),

                  const Divider(),
                  ElevatedButton.icon(
                    onPressed: _isLoadingSettings ? null : _loadCameraStatus,
                    icon: _isLoadingSettings 
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: const Text('刷新状态'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildSliderSetting(
    String label,
    String key,
    int value,
    int min,
    int max,
    List<String>? labels, {
    bool reverse = false,
    bool showValue = false,
    String? info,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                Text(
                  labels != null 
                      ? labels[value.clamp(0, labels.length - 1)]
                      : (showValue ? value.toString() : ''),
                  style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            if (info != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: Text(info, style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ),
            Slider(
              value: value.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: max > min ? (max - min > 100 ? 100 : max - min) : null,
              label: showValue ? value.toString() : null,
              onChanged: (newValue) {
                final intValue = newValue.round();
                _sendCommand(key, reverse ? (max + min - intValue) : intValue);
              },
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildSwitchSetting(String label, String key, dynamic value) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        trailing: Switch(
          value: value is int ? value == 1 : (value is bool ? value : false),
          onChanged: (newValue) {
            _sendCommand(key, newValue ? 1 : 0);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("ESP32-CAM 监控客户端"),
        backgroundColor: Colors.blueGrey,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _isRunning ? _showSettingsPanel : null,
            tooltip: '摄像头设置',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // IP 地址和端口输入
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _ipController,
                    decoration: const InputDecoration(
                      labelText: "ESP32 IP 地址",
                      hintText: "例如: 192.168.4.1",
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.router),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: "端口",
                      hintText: "80",
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.settings_ethernet),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            
            // 控制按钮
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isRunning ? _stopStream : _startPolling,
                    icon: Icon(_isRunning ? Icons.stop : Icons.play_arrow),
                    label: Text(_isRunning ? "停止" : "开始"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isRunning ? Colors.red : Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _takePhoto,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text("拍照"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            
            // 状态信息
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("状态: $_status"),
                  if (_fps > 0)
                    Text("帧率: ${_fps.toStringAsFixed(1)} FPS"),
                ],
              ),
            ),
            const SizedBox(height: 10),
            
            // 视频显示区域
            Expanded(
              child: GestureDetector(
                onTap: _takePhoto,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.black,
                  ),
                  child: _imageBytes == null
                      ? const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.camera_alt, size: 64, color: Colors.grey),
                              SizedBox(height: 10),
                              Text(
                                "点击\"开始\"查看画面\n点击画面可拍照",
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey),
                              ),
                            ],
                          ),
                        )
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
          ],
        ),
      ),
    );
  }
}

