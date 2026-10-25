import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/recommendations/ai_config.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/pressable.dart';

/// User-owned endpoint configuration. The key field is never restored to UI.
class AiSettingsSection extends ConsumerStatefulWidget {
  const AiSettingsSection({super.key});
  @override
  ConsumerState<AiSettingsSection> createState() => _AiSettingsSectionState();
}

class _AiSettingsSectionState extends ConsumerState<AiSettingsSection> {
  final _endpoint = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  AiBackend _backend = AiBackend.openAi;
  bool _initialized = false;
  bool _busy = false;
  bool _showDetails = false;
  String? _message;

  @override
  void dispose() {
    _key.clear();
    _endpoint.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final previous = ref.read(aiSettingsProvider).config;
      await ref
          .read(aiSettingsProvider.notifier)
          .save(
            AiConfig(
              backend: _backend,
              endpoint: _endpoint.text.trim(),
              model: _model.text.trim(),
              listeningConsent: previous.listeningConsent,
            ),
            sessionKey: _key.text.isEmpty ? null : _key.text,
          );
      if (!mounted) return;
      _key.clear();
      if (mounted) {
        setState(
          () => _message = ref.read(aiSettingsProvider).error == null
              ? 'saved — keys last for this app session only'
              : 'could not save configuration on this device',
        );
      }
    } on AiFailure catch (error) {
      if (mounted) setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref.read(aiSettingsProvider.notifier).clear();
      if (!mounted) return;
      _key.clear();
      _model.clear();
      _endpoint.clear();
      setState(
        () => _message = ref.read(aiSettingsProvider).error == null
            ? 'AI settings cleared'
            : 'could not clear configuration on this device',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(aiSettingsProvider);
    if (!settings.ready) return const LinearProgressIndicator();
    if (!_initialized) {
      _initialized = true;
      _endpoint.text = settings.config.endpoint;
      _model.text = settings.config.model;
      _backend = settings.config.backend;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'ai recommendations'),
        const SizedBox(height: AppTheme.headerGap),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppTheme.borderRadius,
            border: AppTheme.border(),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'your model, your endpoint',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              const Text(
                'nothing is sent until you generate and approve '
                'the destination and data.',
                style: TextStyle(fontSize: 12, color: AppColors.textMid),
              ),
              const SizedBox(height: 16),
              const Text('model protocol', style: _labelStyle),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final backend in AiBackend.values)
                    Semantics(
                      selected: _backend == backend,
                      child: _ConfigAction(
                        label: backend == AiBackend.openAi
                            ? 'OpenAI-compatible'
                            : 'Ollama (native)',
                        active: _backend == backend,
                        onTap: _busy
                            ? null
                            : () => setState(() => _backend = backend),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _ConfigField(
                fieldKey: const ValueKey<String>('ai-endpoint'),
                controller: _endpoint,
                enabled: !_busy,
                maxLength: 500,
                label: 'endpoint base URL',
                hint: 'https://api.openai.com/v1',
                technical: true,
              ),
              const SizedBox(height: 12),
              _ConfigField(
                fieldKey: const ValueKey<String>('ai-model'),
                controller: _model,
                enabled: !_busy,
                maxLength: 120,
                label: 'model name',
              ),
              const SizedBox(height: 12),
              _ConfigField(
                fieldKey: const ValueKey<String>('ai-session-key'),
                controller: _key,
                enabled: !_busy,
                maxLength: 4096,
                label: 'API key · session only',
                obscure: true,
              ),
              const SizedBox(height: 6),
              Text(
                settings.hasSessionKey
                    ? 'session key set · leave blank to keep it'
                    : 'optional for local models · never saved to disk',
                style: const TextStyle(fontSize: 11, color: AppColors.textMid),
              ),
              const SizedBox(height: 14),
              Pressable(
                onTap: () => setState(() => _showDetails = !_showDetails),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _showDetails ? Icons.expand_less : Icons.expand_more,
                        size: 14,
                        color: AppColors.textMid,
                      ),
                      const SizedBox(width: 4),
                      const Text('connection & privacy', style: _labelStyle),
                    ],
                  ),
                ),
              ),
              if (_showDetails)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'remote endpoints require HTTPS; HTTP is local only '
                    '(localhost, 127.0.0.1 or ::1). changing the destination '
                    'revokes listening consent and clears the previous key. '
                    'Waveform does not install or download models.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textMid,
                      height: 1.5,
                    ),
                  ),
                ),
              if (settings.config.listeningConsent)
                _ConfigAction(
                  onTap: _busy
                      ? null
                      : () => ref
                            .read(aiSettingsProvider.notifier)
                            .setListeningConsent(false),
                  label: 'revoke listening metadata consent',
                ),
              if (_message != null) ...[
                const SizedBox(height: 8),
                Text(_message!, style: _labelStyle),
              ],
              if (settings.error != null)
                const Text(
                  'configuration could not be read or saved; '
                  'review the fields and save again',
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ConfigAction(
                    onTap: _busy ? null : _save,
                    label: 'save AI settings',
                    active: true,
                  ),
                  _ConfigAction(
                    onTap: _busy ? null : () => context.go('/recommendations'),
                    label: 'open recommendations',
                  ),
                  _ConfigAction(
                    onTap: _busy ? null : _clear,
                    label: 'clear AI settings and key',
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

const _labelStyle = TextStyle(fontSize: 12, color: AppColors.textMid);

class _ConfigField extends StatelessWidget {
  const _ConfigField({
    required this.fieldKey,
    required this.controller,
    required this.enabled,
    required this.maxLength,
    required this.label,
    this.hint,
    this.technical = false,
    this.obscure = false,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final bool enabled;
  final int maxLength;
  final String label;
  final String? hint;
  final bool technical;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    const border = OutlineInputBorder(
      borderRadius: AppTheme.borderRadius,
      borderSide: AppTheme.borderSideStatic,
    );
    return TextField(
      key: fieldKey,
      controller: controller,
      enabled: enabled,
      maxLength: maxLength,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      cursorColor: AppColors.acid,
      style: technical
          ? AppTheme.mono(size: 12, color: AppColors.textHi)
          : const TextStyle(fontSize: 12, color: AppColors.textHi),
      decoration: InputDecoration(
        labelText: label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        labelStyle: _labelStyle,
        floatingLabelStyle: _labelStyle,
        hintText: hint,
        hintStyle: AppTheme.mono(size: 12, color: AppColors.textLow),
        counterText: '',
        filled: true,
        fillColor: AppColors.bg,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: border,
        enabledBorder: border,
        disabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: const BorderSide(
            color: AppColors.acid,
            width: AppTheme.borderWidth,
          ),
        ),
      ),
    );
  }
}

class _ConfigAction extends StatelessWidget {
  const _ConfigAction({required this.label, this.onTap, this.active = false});

  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => Pressable(
    enabled: onTap != null,
    onTap: onTap,
    child: Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: active ? AppColors.acid : AppColors.bg,
          borderRadius: AppTheme.borderRadius,
          border: AppTheme.border(active ? AppColors.acid : AppColors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: active ? AppColors.bg : AppColors.textHi,
          ),
        ),
      ),
    ),
  );
}
