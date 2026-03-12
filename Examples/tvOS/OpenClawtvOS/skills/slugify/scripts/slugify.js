function parseInput(rawInput) {
  const trimmed = String(rawInput ?? "").trim();
  if (!trimmed) {
    return {};
  }
  try {
    return JSON.parse(trimmed);
  } catch {
    return { text: trimmed };
  }
}

function toSlug(text) {
  return String(text ?? "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-");
}

const payload = parseInput(input);
const source = String(payload.text || "").trim();
if (!source) {
  throw new Error("Provide non-empty `text` input.");
}

return JSON.stringify({
  source,
  slug: toSlug(source)
});
