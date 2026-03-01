function parseInput(rawInput) {
  const trimmed = String(rawInput ?? "").trim();
  if (!trimmed) {
    throw new Error("Provide JSON input to format.");
  }
  try {
    return JSON.parse(trimmed);
  } catch {
    return { json: trimmed };
  }
}

function parseJSONValue(value) {
  if (typeof value === "string") {
    return JSON.parse(value);
  }
  return value;
}

function sortKeys(value) {
  if (Array.isArray(value)) {
    return value.map(sortKeys);
  }
  if (value && typeof value === "object") {
    const sorted = {};
    for (const key of Object.keys(value).sort((a, b) => a.localeCompare(b))) {
      sorted[key] = sortKeys(value[key]);
    }
    return sorted;
  }
  return value;
}

const payload = parseInput(input);
const jsonValue = parseJSONValue(payload.json !== undefined ? payload.json : payload);
const stable = sortKeys(jsonValue);

return JSON.stringify({
  pretty: JSON.stringify(stable, null, 2)
});
