import 'package:flutter/material.dart';

import '../core/api/soundcloud_api.dart';
import '../core/api/webview_login.dart';
import 'widgets/toast.dart';

/// Реакция UI на исход API-write (лайк/репост). Тихо при [LikeOutcome.ok]; при
/// `blocked` — предложение пройти верификацию в браузере (капча/анти-абуз,
/// частый под VPN); при `failed` — короткое уведомление с указанием действия.
void showWriteOutcome(
  BuildContext context,
  LikeOutcome outcome, {
  String verb = 'like',
}) {
  if (outcome == LikeOutcome.ok) return;
  final blocked = outcome == LikeOutcome.blocked;
  showToast(
    context,
    blocked
        ? 'SoundCloud blocked this action — likely a captcha/VPN check'
        : "couldn't update $verb",
    duration: Duration(seconds: blocked ? 6 : 3),
    action: blocked
        ? (label: 'verify', onTap: WebviewLogin.openVerification)
        : null,
  );
}

/// Старая точка входа — оставлена для уже-существующих call-сайтов (TrackRow,
/// bottom_player); делегирует в обобщённый [showWriteOutcome].
void showLikeOutcome(BuildContext context, LikeOutcome outcome) =>
    showWriteOutcome(context, outcome, verb: 'like');
