import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_widgets.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputCtrl.text;
    if (text.trim().isEmpty) return;
    context.read<AppState>().sendChat(text);
    _inputCtrl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final units = state.units;

    return Column(
      children: [
        const ScreenHeader(
          title: 'Coach',
          eyebrow: 'Ask anything, or log your session',
        ),
        Expanded(
          child: ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
            itemCount: state.chatMessages.length,
            itemBuilder: (context, i) {
              final m = state.chatMessages[i];
              final isUser = m.sender == 'user';
              return Align(
                alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.78,
                  ),
                  decoration: BoxDecoration(
                    color: isUser ? AppColors.accent : AppColors.surface,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(AppRadii.card),
                      topRight: const Radius.circular(AppRadii.card),
                      bottomLeft: Radius.circular(isUser ? AppRadii.card : 4),
                      bottomRight: Radius.circular(isUser ? 4 : AppRadii.card),
                    ),
                  ),
                  child: Text(
                    m.body,
                    style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      height: 1.45,
                      color: isUser ? AppColors.onAccent : AppColors.textBody,
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // Batch-log confirmation — the coach never writes sets without a check.
        if (state.pendingLog != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Confirm session log',
                    style: TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < state.pendingLog!.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${state.pendingLog![i].exerciseName} · '
                              '${units.formatWeightWithUnit(state.pendingLog![i].weightKg, decimals: 1)}'
                              ' × ${state.pendingLog![i].reps}'
                              ' × ${state.pendingLog![i].sets} sets',
                              style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                color: AppColors.textBody,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => state.removePendingRow(i),
                            child: const Icon(Icons.close_rounded,
                                size: 16, color: AppColors.textFaint),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: state.cancelPendingLog,
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: state.confirmPendingLog,
                          child: const Text('Confirm'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Text(
            'Try: "bench ${units.formatWeight(80)}x8x4, '
            'ohp ${units.formatWeight(40)}x10x3"',
            style: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w600,
              fontSize: 10.5,
              color: AppColors.textFaint,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inputCtrl,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: AppColors.textBody,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Ask your coach…',
                    fillColor: AppColors.surface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: AppColors.accent,
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: _send,
                  customBorder: const CircleBorder(),
                  child: const SizedBox(
                    width: 46,
                    height: 46,
                    child: Icon(Icons.arrow_upward_rounded,
                        color: AppColors.onAccent, size: 20),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
