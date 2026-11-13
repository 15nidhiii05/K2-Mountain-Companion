import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Rough avalanche-danger ESTIMATE from weather only. Not an official bulletin.
class AvalancheEstimate {
  final int index; // 0..4
  const AvalancheEstimate(this.index);

  static const _labels = ['LOW', 'MODERATE', 'CONSIDERABLE', 'HIGH', 'EXTREME'];

  String get label => _labels[index.clamp(0, 4)];

  Color get color {
    if (index <= 0) return Colors.greenAccent;
    if (index == 1) return Colors.yellowAccent;
    if (index == 2) return Colors.orangeAccent;
    return Colors.redAccent;
  }
}

class MountainWeather {
  final double tempC;
  final double windKmh;
  final double gustKmh;
  final double snowfallCm; // last 24 hours
  final double elevationM; // model elevation reported by Open-Meteo
  final DateTime fetchedAt;
  final String locationNote;
  final String conditionText;
  final AvalancheEstimate avalanche;

  const MountainWeather({
    required this.tempC,
    required this.windKmh,
    required this.gustKmh,
    required this.snowfallCm,
    required this.elevationM,
    required this.fetchedAt,
    required this.locationNote,
    required this.conditionText,
    required this.avalanche,
  });

  String get windLabel {
    if (windKmh < 12) return 'Light';
    if (windKmh < 30) return 'Breezy';
    if (windKmh < 40) return 'Strong';
    if (windKmh < 60) return 'Very strong';
    return 'Dangerous';
  }

  bool get _severe => avalanche.index >= 3 || gustKmh >= 70 || tempC <= -30;
  bool get _caution => avalanche.index == 2 || gustKmh >= 50 || tempC <= -20;

  String get verdictTitle {
    if (_severe) return 'SEVERE CONDITIONS. CONSIDER NOT ASCENDING';
    if (_caution) return 'CAUTION. HARSH CONDITIONS';
    return 'NO MAJOR WEATHER FLAGS RIGHT NOW';
  }

  Color get verdictColor {
    if (_severe) return Colors.redAccent;
    if (_caution) return Colors.orangeAccent;
    return Colors.greenAccent;
  }
}

class WeatherService {
  // K2 Base Camp area. Change these to track a different location.
  static const double lat = 35.8825;
  static const double lon = 76.5133;
  static const String place = 'K2 region';

  /// Throws if the network or the API fails. The caller keeps the last data.
  static Future<MountainWeather> fetchCurrent() async {
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat&longitude=$lon'
      '&current=temperature_2m,wind_speed_10m,wind_gusts_10m,weather_code'
      '&hourly=snowfall&past_days=1&forecast_days=1&timezone=auto',
    );
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('Weather API error ${res.statusCode}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final cur = j['current'] as Map<String, dynamic>;

    final temp = (cur['temperature_2m'] as num).toDouble();
    final wind = (cur['wind_speed_10m'] as num).toDouble();
    final gust = (cur['wind_gusts_10m'] as num?)?.toDouble() ?? wind;
    final code = (cur['weather_code'] as num?)?.toInt() ?? 0;
    final nowStr = '${cur['time']}';

    // Sum snowfall over the 24 hours up to the current hour.
    double snow24 = 0;
    final hourly = j['hourly'] as Map<String, dynamic>?;
    if (hourly != null) {
      final times = (hourly['time'] as List).map((e) => '$e').toList();
      final snow = (hourly['snowfall'] as List)
          .map((e) => (e as num?)?.toDouble() ?? 0.0)
          .toList();
      var idx = -1;
      for (var i = 0; i < times.length; i++) {
        if (times[i].compareTo(nowStr) <= 0) idx = i;
      }
      if (idx >= 0) {
        for (var i = (idx - 23).clamp(0, idx); i <= idx; i++) {
          snow24 += snow[i];
        }
      }
    }

    return MountainWeather(
      tempC: temp,
      windKmh: wind,
      gustKmh: gust,
      snowfallCm: snow24,
      elevationM: (j['elevation'] as num?)?.toDouble() ?? 0,
      fetchedAt: DateTime.now(),
      locationNote: place,
      conditionText: _conditionFor(code),
      avalanche: _estimateAvalanche(snow24, wind, temp),
    );
  }

  /// Simple weather-only heuristic. Documented so it can be criticised and
  /// improved. It is NOT a substitute for an official avalanche forecast.
  static AvalancheEstimate _estimateAvalanche(
    double snow24Cm,
    double windKmh,
    double tempC,
  ) {
    int score = 0;
    if (snow24Cm >= 30) {
      score = 3;
    } else if (snow24Cm >= 15) {
      score = 2;
    } else if (snow24Cm >= 5) {
      score = 1;
    }
    if (snow24Cm >= 5 && windKmh >= 50) score += 1; // wind loading
    if (snow24Cm >= 5 && tempC > -1) score += 1; // warming, wet snow
    return AvalancheEstimate(score.clamp(0, 4));
  }

  static String _conditionFor(int code) {
    if (code == 0) return 'Clear';
    if (code <= 2) return 'Partly cloudy';
    if (code == 3) return 'Overcast';
    if (code == 45 || code == 48) return 'Fog';
    if (code >= 51 && code <= 57) return 'Drizzle';
    if (code >= 61 && code <= 67) return 'Rain';
    if (code >= 71 && code <= 77) return 'Snow';
    if (code >= 80 && code <= 82) return 'Rain showers';
    if (code == 85 || code == 86) return 'Snow showers';
    if (code >= 95) return 'Thunderstorm';
    return 'Unsettled';
  }
}
