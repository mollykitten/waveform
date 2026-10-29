import 'package:flutter_driver/driver_extension.dart';

import 'package:waveform_app/main.dart' as app;

Future<void> main(List<String> args) async {
  enableFlutterDriverExtension();
  await app.main(args);
}
