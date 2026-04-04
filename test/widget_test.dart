import 'package:flutter_test/flutter_test.dart';
import 'package:esp32_cam/main.dart'; // 确保这里引用的是你的主文件

void main() {
  testWidgets('Camera App Smoke Test', (WidgetTester tester) async {
    // 将 MyApp 改为 CameraApp，与 main.dart 中的类名一致
    await tester.pumpWidget(const CameraApp());

    // 简单的检查：看 IP 输入框是否存在
    expect(find.text('IP 地址'), findsOneWidget);
  });
}
