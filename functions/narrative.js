"use strict";

const MAX_MEANING_LENGTH = 600;
const MAX_CLUE_COUNT = 8;
const MAX_CLUE_LENGTH = 100;
const MAX_NARRATIVE_LENGTH = 180;

function validateNarrativeInput(data) {
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    throw new Error("invalid-argument");
  }

  for (const key of ["imageData", "imageUrl", "assetId", "photoLocalIdentifier"]) {
    if (data[key] !== undefined && data[key] !== null) {
      throw new Error("photo-data-not-allowed");
    }
  }

  const meaning = normalizeText(data.meaning);
  if (!meaning || meaning.length > MAX_MEANING_LENGTH) {
    throw new Error("invalid-meaning");
  }

  const clues = Array.isArray(data.clues)
    ? data.clues
      .slice(0, MAX_CLUE_COUNT)
      .map(normalizeText)
      .filter(Boolean)
      .map((clue) => clue.slice(0, MAX_CLUE_LENGTH))
    : [];

  return {
    meaning,
    capturedAt: normalizeOptionalText(data.capturedAt, 80),
    cityName: normalizeOptionalText(data.cityName, 100),
    locale: normalizeOptionalText(data.locale, 20) || "ko-KR",
    clues,
  };
}

function buildNarrativeInput(input) {
  return JSON.stringify({
    userMeaning: input.meaning,
    capturedAt: input.capturedAt,
    cityName: input.cityName,
    onDeviceClues: input.clues,
    responseLocale: input.locale,
  });
}

function sanitizeNarrative(text) {
  const normalized = normalizeText(text)
    .replace(/^['"“”]+|['"“”]+$/g, "")
    .slice(0, MAX_NARRATIVE_LENGTH);
  if (!normalized) {
    throw new Error("empty-model-response");
  }
  return normalized;
}

function extractResponseText(payload) {
  if (!payload || !Array.isArray(payload.output)) {
    throw new Error("invalid-model-response");
  }

  for (const item of payload.output) {
    if (!item || !Array.isArray(item.content)) continue;
    for (const content of item.content) {
      if (content && content.type === "output_text" && typeof content.text === "string") {
        return sanitizeNarrative(content.text);
      }
    }
  }
  throw new Error("empty-model-response");
}

function normalizeText(value) {
  return typeof value === "string" ? value.trim().replace(/\s+/g, " ") : "";
}

function normalizeOptionalText(value, maximumLength) {
  const text = normalizeText(value);
  return text ? text.slice(0, maximumLength) : null;
}

module.exports = {
  buildNarrativeInput,
  extractResponseText,
  sanitizeNarrative,
  validateNarrativeInput,
};
