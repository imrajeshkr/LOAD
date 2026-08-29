import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/supabase_service.dart';
import '../../services/supabase_service_v2.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/pressable.dart';

const _patterns = ['push', 'pull', 'legs', 'core'];

String _patternLabel(String p) => switch (p) {
      'push' => 'Push',
      'pull' => 'Pull',
      'legs' => 'Legs',
      'core' => 'Core',
      _ => p,
    };

/// A lifter describes an exercise the catalogue doesn't have. Private by
/// construction — `createExercise` always writes owner_id = the caller and
/// is_core = false, which is exactly what makes the plan generator ignore it.
/// Reached from "Can't find it? Create one" at the bottom of the add-exercise
/// picker (`add_exercise_sheet.dart`), which this deliberately echoes the
/// visual language of.
///
/// The photo is optional throughout: skipping it, or a failed upload, leaves
/// the same placeholder a catalogue lift with no illustration gets. Neither
/// ever blocks saving the exercise itself.
///
/// Returns the new exercise id, or null if cancelled.
Future<String?> showCreateExerciseSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _CreateExerciseSheet(),
  );
}

class _CreateExerciseSheet extends StatefulWidget {
  const _CreateExerciseSheet();
  @override
  State<_CreateExerciseSheet> createState() => _CreateExerciseSheetState();
}

class _CreateExerciseSheetState extends State<_CreateExerciseSheet> {
  final _nameCtrl = TextEditingController();
  String? _pattern;
  String? _muscleId;
  String? _equipmentId;
  bool _bodyweight = false;
  Uint8List? _photoBytes;
  String _photoExt = 'jpg';

  List<(String, String)> _muscles = const [];
  List<(String, String)> _equipment = const [];
  bool _optionsLoading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    try {
      final svc = SupabaseService.instance;
      final results = await Future.wait([
        svc.fetchMuscleOptions(),
        svc.fetchEquipmentOptions(),
      ]);
      if (mounted) {
        setState(() {
          _muscles = results[0];
          _equipment = results[1];
          _optionsLoading = false;
        });
      }
    } catch (_) {
      // Optional filters — a lifter can still name and save the exercise.
      if (mounted) setState(() => _optionsLoading = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  bool get _canSave => _nameCtrl.text.trim().isNotEmpty && _pattern != null && !_saving;

  Future<void> _pickPhoto() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 1200, imageQuality: 85);
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    final ext = picked.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
    setState(() {
      _photoBytes = bytes;
      _photoExt = ext;
    });
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final svc = SupabaseService.instance;
    try {
      final id = await svc.createExercise(
        name: _nameCtrl.text.trim(),
        pattern: _pattern!,
        muscleId: _muscleId,
        equipmentId: _equipmentId,
        bodyweight: _bodyweight,
      );
      if (id == null) {
        if (mounted) {
          setState(() {
            _saving = false;
            _error = "Couldn't save that — try again.";
          });
        }
        return;
      }
      final photo = _photoBytes;
      if (photo != null) {
        try {
          await svc.uploadExerciseDemo(exerciseId: id, bytes: photo, ext: _photoExt);
        } catch (_) {
          // Never fatal: the exercise is saved either way, just without a
          // photo — same placeholder a catalogue lift with none gets.
        }
      }
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = "Couldn't save that exercise.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
        decoration: const BoxDecoration(
          color: AppColors.surfaceRaised,
          border: Border(top: BorderSide(color: AppColors.border)),
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: EdgeInsets.fromLTRB(20, 10, 20, 16 + MediaQuery.of(context).padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: AppColors.borderStrong, borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const Text('CREATE AN EXERCISE',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 9.5,
                    letterSpacing: 0.7,
                    color: AppColors.accent)),
            const SizedBox(height: 6),
            const Text('Describe your own lift',
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 4),
            const Text("Just for you — it never shows up in anyone else's plan.",
                style: TextStyle(
                    fontFamily: AppTheme.fontFamily, fontSize: 11.5, color: AppColors.textMuted)),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('NAME'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _nameCtrl,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily, fontSize: 14, color: AppColors.textPrimary),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'e.g. Landmine press',
                        hintStyle: const TextStyle(
                            fontFamily: AppTheme.fontFamily, fontSize: 13, color: AppColors.textFaint),
                        filled: true,
                        fillColor: AppColors.surface,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: AppColors.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: AppColors.border),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _label('PATTERN'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final p in _patterns)
                          _Chip(
                            label: _patternLabel(p),
                            selected: _pattern == p,
                            onTap: () => setState(() => _pattern = _pattern == p ? null : p),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _label('MUSCLE (OPTIONAL)'),
                    const SizedBox(height: 8),
                    _optionsLoading
                        ? const _OptionsLoading()
                        : Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final m in _muscles)
                                _Chip(
                                  label: m.$2,
                                  selected: _muscleId == m.$1,
                                  onTap: () =>
                                      setState(() => _muscleId = _muscleId == m.$1 ? null : m.$1),
                                ),
                            ],
                          ),
                    const SizedBox(height: 16),
                    _label('EQUIPMENT (OPTIONAL)'),
                    const SizedBox(height: 8),
                    _optionsLoading
                        ? const _OptionsLoading()
                        : Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final eq in _equipment)
                                _Chip(
                                  label: eq.$2,
                                  selected: _equipmentId == eq.$1,
                                  onTap: () => setState(
                                      () => _equipmentId = _equipmentId == eq.$1 ? null : eq.$1),
                                ),
                            ],
                          ),
                    const SizedBox(height: 16),
                    _ToggleRow(
                      label: 'Bodyweight',
                      sub: 'No external load — reps only, no weight control.',
                      value: _bodyweight,
                      onChanged: (v) => setState(() => _bodyweight = v),
                    ),
                    const SizedBox(height: 16),
                    _label('PHOTO (OPTIONAL)'),
                    const SizedBox(height: 8),
                    _PhotoPicker(bytes: _photoBytes, onTap: _pickPhoto),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Text(_error!,
                          style: const TextStyle(
                              fontFamily: AppTheme.fontFamily, fontSize: 12, color: AppColors.accent)),
                    ],
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Pressable(
              haptic: PressFx.medium,
              onTap: _canSave ? _save : null,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 15),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _canSave ? AppColors.accent : AppColors.surfaceSunken,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.onAccent))
                    : Text('Save exercise',
                        style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: _canSave ? AppColors.onAccent : AppColors.textFaint)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: 9.5,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w700,
          color: AppColors.textFaint));
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      haptic: PressFx.light,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AppColors.accent : AppColors.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w500,
                fontSize: 12.5,
                color: selected ? AppColors.onAccent : AppColors.textMuted)),
      ),
    );
  }
}

class _OptionsLoading extends StatelessWidget {
  const _OptionsLoading();
  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 20,
      width: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final String? sub;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({required this.label, this.sub, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      haptic: PressFx.light,
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                        color: AppColors.textPrimary)),
                if (sub != null) ...[
                  const SizedBox(height: 3),
                  Text(sub!,
                      style: const TextStyle(
                          fontFamily: AppTheme.fontFamily, fontSize: 10.5, color: AppColors.textMuted)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _Switch(value: value),
        ],
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  final bool value;
  const _Switch({required this.value});
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: 44,
      height: 26,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: value ? AppColors.accent : AppColors.border,
        borderRadius: BorderRadius.circular(14),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 220),
        curve: const Cubic(0.22, 1, 0.36, 1),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 20,
          height: 20,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _PhotoPicker extends StatelessWidget {
  final Uint8List? bytes;
  final VoidCallback onTap;
  const _PhotoPicker({required this.bytes, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      haptic: PressFx.light,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 110,
          width: double.infinity,
          color: AppColors.surface,
          child: bytes != null
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(bytes!, fit: BoxFit.cover),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xD1100E0D),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text('Change',
                            style: TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w500,
                                fontSize: 10.5,
                                color: Colors.white)),
                      ),
                    ),
                  ],
                )
              : DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_a_photo_rounded, size: 24, color: AppColors.textFaint),
                        SizedBox(height: 6),
                        Text('Add a photo',
                            style: TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w500,
                                fontSize: 11.5,
                                color: AppColors.textMuted)),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
