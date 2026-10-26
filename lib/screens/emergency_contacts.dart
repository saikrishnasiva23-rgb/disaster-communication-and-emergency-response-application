import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class EmergencyContactsScreen extends StatelessWidget {
  const EmergencyContactsScreen({super.key});

  Future<void> _call(BuildContext context, String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    final launched = await launchUrl(uri);

    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not start a call to $number")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Emergency Contacts"),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.local_hospital, color: Colors.red),
            title: const Text("Ambulance"),
            subtitle: const Text("108"),
            trailing: IconButton(
              icon: const Icon(Icons.call),
              onPressed: () => _call(context, "108"),
            ),
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.local_fire_department, color: Colors.orange),
            title: const Text("Fire Service"),
            subtitle: const Text("101"),
            trailing: IconButton(
              icon: const Icon(Icons.call),
              onPressed: () => _call(context, "101"),
            ),
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.local_police, color: Colors.blue),
            title: const Text("Police"),
            subtitle: const Text("100"),
            trailing: IconButton(
              icon: const Icon(Icons.call),
              onPressed: () => _call(context, "100"),
            ),
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.warning, color: Colors.amber),
            title: const Text("Disaster Management"),
            subtitle: const Text("1070"),
            trailing: IconButton(
              icon: const Icon(Icons.call),
              onPressed: () => _call(context, "1070"),
            ),
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.family_restroom, color: Colors.green),
            title: const Text("Family Contact"),
            subtitle: const Text("+91 9876543210"),
            trailing: IconButton(
              icon: const Icon(Icons.call),
              onPressed: () => _call(context, "+91 9876543210"),
            ),
          ),
        ],
      ),
    );
  }
}
