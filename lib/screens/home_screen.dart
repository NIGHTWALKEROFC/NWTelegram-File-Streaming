// lib/screens/home_screen.dart
//
// Starts the streaming proxy and delegates to FilesScreen.
// Keeping this file so the '/home' route in main.dart works unchanged.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/stream_service.dart';
import '../services/telegram_service.dart';
import 'files_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final streamService = context.read<StreamService>();
      final telegramService = context.read<TelegramService>();
      if (!streamService.isRunning) {
        await streamService.startServer(telegramService);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return const FilesScreen();
  }
}
