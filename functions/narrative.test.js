"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  buildNarrativeInput,
  extractResponseText,
  validateNarrativeInput,
} = require("./narrative");

test("normalizes allowed narrative inputs", () => {
  const input = validateNarrativeInput({
    meaning: "  남해에서 함께 본 바다  ",
    capturedAt: "2026-07-20",
    cityName: "남해",
    locale: "ko-KR",
    clues: ["  풍경 사진  ", "노출이 적절함"],
  });

  assert.equal(input.meaning, "남해에서 함께 본 바다");
  assert.deepEqual(input.clues, ["풍경 사진", "노출이 적절함"]);
  assert.match(buildNarrativeInput(input), /남해/);
});

test("rejects raw photo data and identifiers", () => {
  assert.throws(
    () => validateNarrativeInput({ meaning: "기억", imageData: "base64" }),
    /photo-data-not-allowed/,
  );
  assert.throws(
    () => validateNarrativeInput({ meaning: "기억", photoLocalIdentifier: "asset-id" }),
    /photo-data-not-allowed/,
  );
});

test("extracts and normalizes one output text item", () => {
  const text = extractResponseText({
    output: [{
      type: "message",
      content: [{ type: "output_text", text: "  바다를 바라보던 고요한 오후를 남겼어요.  " }],
    }],
  });

  assert.equal(text, "바다를 바라보던 고요한 오후를 남겼어요.");
});
