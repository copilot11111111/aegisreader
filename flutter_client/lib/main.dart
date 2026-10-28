import 'package:flutter/material.dart';
import 'services/window_snap_back_service.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WindowSnapBackService.initialize(
    initialWidth: 830,
    initialHeight: 830,
  );
  runApp(const AegisReaderApp());
}

class AegisReaderApp extends StatelessWidget {
  const AegisReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'aegisreader',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const HomePage(),
    );
  }
}
