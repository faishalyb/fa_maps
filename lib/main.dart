import 'package:flutter/material.dart';

import 'app.dart';
import 'core/db.dart';
import 'core/settings.dart';
import 'services/feature_repository.dart';
import 'services/map_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.instance.load();
  await AppDatabase.instance.open();
  await MapRepository.instance.load();
  await FeatureRepository.instance.load();
  runApp(const PetaKebunApp());
}
