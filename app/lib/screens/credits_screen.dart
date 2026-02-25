import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const List<_TeamMember> _members = [
    _TeamMember(name: "Kim Trumata", role: "Leader"),
    _TeamMember(name: "Red Javeed Gonzales"),
    _TeamMember(name: "Louille Serqueña"),
    _TeamMember(name: "Lawrence Clavio"),
    _TeamMember(name: "Alliyah Gabrielle Mendoza"),
    _TeamMember(name: "Meia Benjamin Serduar"),
    _TeamMember(name: "Edzel Diamonon"),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("About")),
      body: Container(
        width: double.infinity,
        color: const Color(0xFFEAF7EE),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFD4F0DD),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                "Smart Medicine Reminder Researcher",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F5132),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: _members.length,
                separatorBuilder: (_, index) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final member = _members[index];
                  return Card(
                    color: Colors.white,
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFF2E7D32),
                        foregroundColor: Colors.white,
                        child: Text("${index + 1}"),
                      ),
                      title: Text(member.name),
                      subtitle: Text(member.role),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeamMember {
  final String name;
  final String role;

  const _TeamMember({required this.name, this.role = "Member"});
}
