import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('隐私说明')),
    body: FutureBuilder<String>(
      future: rootBundle.loadString('PRIVACY.md'),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('无法读取隐私说明：${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(snapshot.data!),
        );
      },
    ),
  );
}
