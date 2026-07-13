import 'package:flutter_test/flutter_test.dart';
import 'package:shujiapp/main.dart';

void main() {
  testWidgets('App should render navigation', (WidgetTester tester) async {
    await tester.pumpWidget(const ObjDetectApp());
    expect(find.text('检测'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
