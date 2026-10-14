import 'package:flutter_test/flutter_test.dart';
import 'package:my_music_player/main.dart';

void main() {
  testWidgets('My Music Player loads', (WidgetTester tester) async {
    await tester.pumpWidget(const MyMusicPlayer());
    expect(find.byType(MyMusicPlayer), findsOneWidget);
  });
}
