function parseInput(rawInput) {
  const trimmed = String(rawInput ?? "").trim();
  if (!trimmed) {
    return {};
  }
  try {
    return JSON.parse(trimmed);
  } catch {
    return { expression: trimmed };
  }
}

function ensureNumber(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    throw new Error(`Invalid number: ${value}`);
  }
  return parsed;
}

function evaluateOperation(payload) {
  const operation = String(payload.operation || "").trim().toLowerCase();
  const values = Array.isArray(payload.values) ? payload.values.map(ensureNumber) : [];
  if (!operation || values.length == 0) {
    throw new Error("Operation mode requires `operation` and non-empty `values`.");
  }

  switch (operation) {
    case "add":
      return values.reduce((sum, value) => sum + value, 0);
    case "subtract":
      return values.slice(1).reduce((total, value) => total - value, values[0]);
    case "multiply":
      return values.reduce((total, value) => total * value, 1);
    case "divide":
      return values.slice(1).reduce((total, value) => {
        if (value === 0) {
          throw new Error("Division by zero.");
        }
        return total / value;
      }, values[0]);
    default:
      throw new Error(`Unsupported operation: ${operation}`);
  }
}

function evaluateExpression(payload) {
  const expression = String(payload.expression || "").trim();
  if (!expression) {
    throw new Error("Expression mode requires `expression`.");
  }
  if (!/^[0-9+\-*/().\s]+$/.test(expression)) {
    throw new Error("Expression contains unsupported characters.");
  }
  const value = Function(`"use strict"; return (${expression});`)();
  if (!Number.isFinite(value)) {
    throw new Error("Expression did not evaluate to a finite number.");
  }
  return value;
}

const payload = parseInput(input);
const usingOperationMode = payload.operation !== undefined || payload.values !== undefined;
const result = usingOperationMode ? evaluateOperation(payload) : evaluateExpression(payload);

return JSON.stringify({
  mode: usingOperationMode ? "operation" : "expression",
  result
});
