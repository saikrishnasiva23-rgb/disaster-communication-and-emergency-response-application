import 'package:flutter/material.dart';

class EmergencyMessagesScreen extends StatefulWidget {
  const EmergencyMessagesScreen({super.key});

  @override
  State<EmergencyMessagesScreen> createState() =>
      _EmergencyMessagesScreenState();
}

class _EmergencyMessagesScreenState
    extends State<EmergencyMessagesScreen> {
  final List<String> messages = [
    "🚨 Fire reported near City Center",
    "🚑 Medical emergency at Highway 45",
    "🌊 Flood warning in Riverside Area",
    "⚠️ Building collapse reported",
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Emergency Messages"),
      ),
      body: ListView.builder(
        itemCount: messages.length,
        itemBuilder: (context, index) {
          return Card(
            margin: const EdgeInsets.all(10),
            child: ListTile(
              leading: const Icon(
                Icons.warning,
                color: Colors.red,
              ),
              title: Text(messages[index]),
            ),
          );
        },
      ),
    );
  }
}