function parseInput(rawInput) {
  const trimmed = String(rawInput ?? "").trim();
  if (!trimmed) {
    return {};
  }
  try {
    return JSON.parse(trimmed);
  } catch {
    const inferred = inferLocationFromSentence(trimmed);
    return { location: inferred || trimmed };
  }
}

function inferLocationFromSentence(text) {
  const normalized = String(text ?? "").replace(/\s+/g, " ").trim();
  if (!normalized) {
    return "";
  }

  const inMatch = normalized.match(/\bin\s+([A-Za-z][A-Za-z\s\-.'`]{1,80})/i);
  if (inMatch && inMatch[1]) {
    let location = inMatch[1]
      .replace(/\b(today|tomorrow|now|right now|please|for)\b.*$/i, "")
      .replace(/[?!.,;:]+$/g, "")
      .trim();
    if (location.toLowerCase().startsWith("the ")) {
      location = location.slice(4);
    }
    if (location) {
      return location;
    }
  }

  if (/^[A-Za-z][A-Za-z\s\-.'`]{1,80}$/.test(normalized)) {
    return normalized;
  }
  return "";
}

function getJSON(url) {
  const body = httpGet(url);
  return JSON.parse(body);
}

function resolveCoordinates(payload) {
  if (payload.latitude !== undefined && payload.longitude !== undefined) {
    const latitude = Number(payload.latitude);
    const longitude = Number(payload.longitude);
    const fallbackName = Number.isFinite(latitude) && Number.isFinite(longitude)
      ? `${latitude.toFixed(4)},${longitude.toFixed(4)}`
      : "unknown";
    const resolvedName = String(payload.location || fallbackName);
    return { latitude, longitude, resolvedName };
  }

  const location = String(payload.location || "").trim();
  if (!location) {
    throw new Error("Input must include `location` or (`latitude`, `longitude`).");
  }

  const geoQuery = `name=${encodeURIComponent(location)}&count=1&language=en&format=json`;
  const geoURL = `https://geocoding-api.open-meteo.com/v1/search?${geoQuery}`;
  const geoData = getJSON(geoURL);
  const result = Array.isArray(geoData.results) ? geoData.results[0] : null;
  if (!result) {
    throw new Error(`No geocoding result for location: ${location}`);
  }

  const latitude = Number(result.latitude);
  const longitude = Number(result.longitude);
  const country = result.country_code || result.country || "";
  const resolvedName = `${result.name || location}${country ? `, ${country}` : ""}`;
  return { latitude, longitude, resolvedName };
}

const payload = parseInput(input);
const { latitude, longitude, resolvedName } = resolveCoordinates(payload);
const forecastQuery = [
  `latitude=${encodeURIComponent(latitude)}`,
  `longitude=${encodeURIComponent(longitude)}`,
  "current=temperature_2m,weather_code,wind_speed_10m",
  "daily=temperature_2m_max,temperature_2m_min,weather_code",
  "timezone=auto",
  "forecast_days=1"
].join("&");
const forecastURL = `https://api.open-meteo.com/v1/forecast?${forecastQuery}`;
const forecast = getJSON(forecastURL);

const current = forecast.current || {};
const daily = forecast.daily || {};
const output = {
  resolved_location: resolvedName,
  latitude,
  longitude,
  current: {
    temperature_c: current.temperature_2m ?? null,
    weather_code: current.weather_code ?? null,
    wind_kmh: current.wind_speed_10m ?? null
  },
  today: {
    temp_max_c: Array.isArray(daily.temperature_2m_max) ? daily.temperature_2m_max[0] : null,
    temp_min_c: Array.isArray(daily.temperature_2m_min) ? daily.temperature_2m_min[0] : null,
    weather_code: Array.isArray(daily.weather_code) ? daily.weather_code[0] : null
  }
};

return JSON.stringify(output);
