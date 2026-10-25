import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/recommendations/ai_config.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/widgets/section_header.dart';

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
                'use your own model endpoint. nothing is sent until '
                'you generate and approve the destination and data.',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AiBackend>(
                initialValue: _backend,
                decoration: const InputDecoration(labelText: 'model protocol'),
                items: const [
                  DropdownMenuItem(
                    value: AiBackend.openAi,
                    child: Text('OpenAI-compatible'),
                  ),
                  DropdownMenuItem(
                    value: AiBackend.ollama,
                    child: Text('Ollama (native)'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) setState(() => _backend = value);
                      },
              ),
              TextField(
                key: const ValueKey<String>('ai-endpoint'),
                controller: _endpoint,
                enabled: !_busy,
                maxLength: 500,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'endpoint base URL',
                  hintText:
                      'https://api.openai.com/v1 or http://localhost:11434',
                ),
              ),
              TextField(
                key: const ValueKey<String>('ai-model'),
                controller: _model,
                enabled: !_busy,
                maxLength: 120,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'model name'),
              ),
              TextField(
                key: const ValueKey<String>('ai-session-key'),
                controller: _key,
                enabled: !_busy,
                obscureText: true,
                maxLength: 4096,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText:
                      'API key — session only (optional for local models)',
                  helperText: settings.hasSessionKey
                      ? 'a session key is set; leave blank to keep it'
                      : 'no key stored; paste one if your endpoint requires it',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'remote endpoints require HTTPS. HTTP is allowed only '
                'for localhost, 127.0.0.1 or ::1. changing the destination '
                'revokes listening consent and clears the previous key. '
                'no model is installed or downloaded by Waveform.',
              ),
              if (settings.config.listeningConsent)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => ref
                            .read(aiSettingsProvider.notifier)
                            .setListeningConsent(false),
                  child: const Text('revoke listening metadata consent'),
                ),
              if (_message != null) ...[
                const SizedBox(height: 8),
                Text(_message!, style: AppTheme.mono(size: 11)),
              ],
              if (settings.error != null)
                const Text(
                  'configuration could not be read or saved; '
                  'review the fields and save again',
                ),
              Wrap(
                spacing: 12,
                children: [
                  TextButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('save AI settings'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => context.go('/recommendations'),
                    child: const Text('open recommendations'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _clear,
                    child: const Text('clear AI settings and key'),
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
