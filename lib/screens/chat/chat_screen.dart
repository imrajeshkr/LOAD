import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  void _send() {
    final text = _inputCtrl.text;
    if (text.trim().isEmpty) return;
    context.read<AppState>().sendChat(text);
    _inputCtrl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Align(alignment: Alignment.centerLeft, child: Text('Chat', style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700))),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            controller: _scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            children: state.chatMessages
                .map((m) => Align(
                      alignment: m.sender == 'user' ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                        decoration: BoxDecoration(
                          color: m.sender == 'user' ? AppColors.accent : AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(m.body, style: TextStyle(color: m.sender == 'user' ? AppColors.accentOn : AppColors.textPrimary, fontSize: 13, height: 1.4)),
                      ),
                    ))
                .toList(),
          ),
        ),
        if (state.pendingLog != null)
          Container(
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(14)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('CONFIRM SESSION LOG', style: TextStyle(color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                const SizedBox(height: 8),
                ...state.pendingLog!.map((row) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text('${row.exerciseName} — ${row.weight.toStringAsFixed(0)} lb × ${row.reps} × ${row.sets} sets',
                          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
                    )),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: OutlinedButton(onPressed: state.cancelPendingLog, child: const Text('Cancel'))),
                    const SizedBox(width: 8),
                    Expanded(child: ElevatedButton(onPressed: state.confirmPendingLog, child: const Text('Confirm'))),
                  ],
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Text('TRY: "logged bench 185x8x4, ohp 95x10x3"', style: const TextStyle(color: AppColors.textTertiary, fontSize: 10)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputCtrl,
                  decoration: const InputDecoration(hintText: 'Ask your coach…'),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _send,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(12)),
                  child: const Text('Send', style: TextStyle(color: AppColors.accentOn, fontWeight: FontWeight.w700, fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
