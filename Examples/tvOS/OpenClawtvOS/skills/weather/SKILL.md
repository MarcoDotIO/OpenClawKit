---
name: weather
description: Fetch current conditions and today forecast using Open-Meteo.
entrypoint: scripts/weather.js
primaryEnv: node
user-invocable: true
disable-model-invocation: false
---

Use this skill when a user asks for weather, temperature, or forecast details.

Input contract (JSON):
- `location` (optional string): City name for geocoding lookup.
- `latitude` and `longitude` (optional numbers): Direct coordinates.

At least one of these combinations is required:
- `location`, or
- both `latitude` and `longitude`.

Execution:
- Run `skills/weather/scripts/weather.js` through the OpenClaw skill engine.
- Pass JSON input as the single argument (or `input` string in JS runtime).
- The script uses free Open-Meteo endpoints and does not require an API key.

Output contract (JSON):
- `resolved_location`: Human-readable location used for the query.
- `latitude` / `longitude`: Coordinates used for forecast request.
- `current`: Object with current temperature, weather code, and wind speed.
- `today`: Object with max/min temperature and weather code.

Example input:
```json
{"location":"Milan"}
```

Example output:
```json
{"resolved_location":"Milan, IT","latitude":45.4643,"longitude":9.1895,"current":{"temperature_c":8.1,"weather_code":2,"wind_kmh":7.4},"today":{"temp_max_c":11.2,"temp_min_c":3.5,"weather_code":3}}
```
