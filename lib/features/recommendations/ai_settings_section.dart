import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/recommendations/ai_config.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/form_controls.dart';
import 'wave_controls.dart';

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

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await operation();
    } on AiFailure catch (failure) {
      if (mounted) setState(() => _message = failure.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run(() async {
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
    setState(
      () => _message = ref.read(aiSettingsProvider).error == null
          ? 'custom provider saved — keys last for this app session only'
          : 'could not save configuration on this device',
    );
  });

  Future<void> _clear() => _run(() async {
    await ref.read(aiSettingsProvider.notifier).clear();
    if (!mounted) return;
    _key.clear();
    _model.clear();
    _endpoint.clear();
    setState(() {
      _backend = AiBackend.openAi;
      _message = ref.read(aiSettingsProvider).error == null
          ? 'custom settings cleared'
          : 'could not clear configuration on this device';
    });
  });

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(aiSettingsProvider);
    if (!settings.ready) return const LinearProgressIndicator();
    if (!_initialized) {
      _initialized = true;
      _endpoint.text = settings.config.endpoint;
      _model.text = settings.config.model;
      _backend = settings.config.backend == AiBackend.chatGpt
          ? AiBackend.openAi
          : settings.config.backend;
    }
    final busy = _busy || settings.connecting;
    final controller = ref.read(aiSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'my wave'),
        const SizedBox(height: AppTheme.headerGap),
        WaveConnectionCard(
          connected: settings.chatGptConnected,
          busy: busy,
          onConnect: () => _run(controller.connectChatGpt),
          onDisconnect: () => _run(controller.disconnectChatGpt),
          message: settings.error?.message ?? _message,
          accountLabel: settings.chatGptAccountLabel,
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(
                  height: .5,
                  thickness: .5,
                  color: AppColors.border,
                ),
              ),
              WaveControlRow(
                information: Text(
                  settings.config.listeningConsent
                      ? 'personalisation is on for this destination and account.'
                      : 'listening metadata stays private until you allow it when starting your wave.',
                  style: formTextStyle,
                ),
                actions:
                    settings.config.listeningConsent ||
                        (settings.chatGptConnected &&
                            settings.config.backend != AiBackend.chatGpt)
                    ? Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (settings.config.listeningConsent)
                            FormAction(
                              kind: FormActionKind.quiet,
                              onTap: busy
                                  ? null
                                  : () => _run(
                                      () =>
                                          controller.setListeningConsent(false),
                                    ),
                              label: 'turn off personalisation',
                            ),
                          if (settings.chatGptConnected &&
                              settings.config.backend != AiBackend.chatGpt)
                            FormAction(
                              kind: FormActionKind.quiet,
                              onTap: busy
                                  ? null
                                  : () => _run(controller.useChatGpt),
                              label: 'use ChatGPT for my wave',
                            ),
                        ],
                      )
                    : null,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FormAction(
                    onTap: busy ? null : () => context.go('/recommendations'),
                    label: 'open my wave',
                  ),
                  if (settings.error == AiFailure.credentials &&
                      settings.chatGptConnected)
                    FormAction(
                      onTap: busy
                          ? null
                          : () => _run(controller.connectChatGpt),
                      label: 'reconnect ChatGPT',
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        DecoratedBox(
          decoration: BoxDecoration(
            border: AppTheme.border(),
            borderRadius: AppTheme.borderRadius,
          ),
          child: ExpansionTile(
            key: const ValueKey('wave-advanced-settings'),
            title: Text('advanced settings', style: formHeadingStyle),
            subtitle: const Text('use your own provider', style: formTextStyle),
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              FormAction(
                kind: FormActionKind.quiet,
                onTap: busy
                    ? null
                    : () => _run(
                        () => controller.connectChatGpt(newAccount: true),
                      ),
                label: 'use another ChatGPT account',
                icon: Icons.switch_account_outlined,
                iconSize: 16,
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
              const Text(
                'custom providers are optional. changing the destination '
                'revokes listening consent. no model server is started or downloaded.',
                style: formTextStyle,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final backend in [AiBackend.openAi, AiBackend.ollama])
                    Semantics(
                      selected: _backend == backend,
                      child: _ConfigAction(
                        label: backend == AiBackend.openAi
                            ? 'OpenAI-compatible'
                            : 'Ollama (native)',
                        active: _backend == backend,
                        onTap: busy
                            ? null
                            : () => setState(() => _backend = backend),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _ConfigField(
                fieldKey: const ValueKey('ai-endpoint'),
                controller: _endpoint,
                enabled: !busy,
                maxLength: 500,
                label: 'endpoint base URL',
                hint: 'https://api.openai.com/v1',
                technical: true,
              ),
              const SizedBox(height: 12),
              _ConfigField(
                fieldKey: const ValueKey('ai-model'),
                controller: _model,
                enabled: !busy,
                maxLength: 120,
                label: 'model name',
              ),
              const SizedBox(height: 12),
              _ConfigField(
                fieldKey: const ValueKey('ai-session-key'),
                controller: _key,
                enabled: !busy,
                maxLength: 4096,
                label: 'API key · session only',
                obscure: true,
              ),
              const SizedBox(height: 8),
              Text(
                settings.hasSessionKey
                    ? 'session key set · leave blank to keep it'
                    : 'optional for local models · never saved to disk',
                style: formTextStyle,
              ),
              const SizedBox(height: 12),
              const Text(
                'HTTPS is required for remote providers. HTTP is only '
                'allowed on loopback. your provider may charge for requests.',
                style: formTextStyle,
              ),
              if (_message != null) ...[
                const SizedBox(height: 8),
                Text(_message!, style: formTextStyle),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ConfigAction(
                    onTap: busy ? null : _save,
                    label: 'save custom provider',
                    active: true,
                  ),
                  _ConfigAction(
                    onTap: busy ? null : _clear,
                    label: 'clear custom settings',
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
  Widget build(BuildContext context) => FormFieldLabel(
    label: label,
    child: TextField(
      key: fieldKey,
      controller: controller,
      enabled: enabled,
      maxLength: maxLength,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      cursorColor: AppColors.acid,
      style: technical || obscure
          ? AppTheme.mono(size: 13, color: AppColors.textHi)
          : const TextStyle(fontSize: 13, height: 1.5, color: AppColors.textHi),
      decoration: formInputDecoration(hint: hint),
    ),
  );
}

class _ConfigAction extends StatelessWidget {
  const _ConfigAction({required this.label, this.onTap, this.active = false});

  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => FormAction(
    label: label,
    onTap: onTap,
    kind: active ? FormActionKind.primary : FormActionKind.secondary,
    selected: active,
  );
}
