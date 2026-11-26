"use strict";

const { logger } = require("firebase-functions");
const { defineSecret, defineString } = require("firebase-functions/params");
const { HttpsError, onCall } = require("firebase-functions/v2/https");
const {
  buildNarrativeInput,
  extractResponseText,
  validateNarrativeInput,
} = require("./narrative");

const openAiApiKey = defineSecret("OPENAI_API_KEY");
const openAiModel = defineString("OPENAI_MODEL");

exports.generateNarrative = onCall(
  {
    region: "asia-northeast3",
    timeoutSeconds: 30,
    memory: "256MiB",
    maxInstances: 10,
    secrets: [openAiApiKey],
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication is required.");
    }

    let input;
    try {
      input = validateNarrativeInput(request.data);
    } catch (error) {
      const code = error instanceof Error ? error.message : "invalid-argument";
      throw new HttpsError("invalid-argument", code);
    }

    const model = openAiModel.value().trim();
    if (!model) {
      logger.error("OPENAI_MODEL is not configured.");
      throw new HttpsError("failed-precondition", "AI model is not configured.");
    }

    let response;
    try {
      response = await fetch("https://api.openai.com/v1/responses", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${openAiApiKey.value()}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          store: false,
          max_output_tokens: 160,
          instructions: [
            "You polish a private photo-memory note.",
            "Use only the supplied facts and never infer identity, relationships, or emotions as facts.",
            "Return one restrained sentence in the requested locale, without a title, quote marks, or hashtags.",
          ].join(" "),
          input: buildNarrativeInput(input),
        }),
      });
    } catch (error) {
      logger.error("OpenAI request failed before receiving a response.", {
        errorName: error instanceof Error ? error.name : "unknown",
      });
      throw new HttpsError("unavailable", "AI service is temporarily unavailable.");
    }

    if (!response.ok) {
      logger.error("OpenAI returned an error response.", {
        status: response.status,
        requestId: response.headers.get("x-request-id"),
      });
      throw new HttpsError("unavailable", "AI service is temporarily unavailable.");
    }

    try {
      const payload = await response.json();
      return {
        narrative: extractResponseText(payload),
        keywords: [],
      };
    } catch (error) {
      logger.error("OpenAI response could not be parsed.", {
        errorName: error instanceof Error ? error.name : "unknown",
      });
      throw new HttpsError("internal", "AI response could not be processed.");
    }
  },
);
