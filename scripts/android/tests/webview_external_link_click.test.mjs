import assert from "node:assert/strict";
import test from "node:test";

import {
  normalizeNeedle,
  pickActivationPoint,
} from "../webview-external-link-click.mjs";

test("normalizes spaced WebView link labels for stable matching", () => {
  assert.equal(normalizeNeedle("oldschool .runescape .com"), "oldschool.runescape.com");
  assert.equal(normalizeNeedle(" Old School RuneScape "), "old school runescape");
});

test("picks a positive DOM hit-test point instead of a zero-height accessibility bound", () => {
  const point = pickActivationPoint(
    [
      {
        href: "https://oldschool.runescape.com/",
        text: "oldschool .runescape .com",
        rects: [
          {
            left: 467,
            top: 2078,
            right: 904,
            bottom: 2078,
            width: 437,
            height: 0,
            hitMatchesAnchor: true,
          },
        ],
      },
      {
        href: "https://oldschool.runescape.com/",
        text: "oldschool.runescape.com",
        rects: [
          {
            left: 467,
            top: 520,
            right: 904,
            bottom: 576,
            width: 437,
            height: 56,
            hitMatchesAnchor: true,
          },
        ],
      },
    ],
    { viewportWidth: 1080, viewportHeight: 1764 },
  );

  assert.equal(point.href, "https://oldschool.runescape.com/");
  assert.equal(point.x, 685.5);
  assert.equal(point.y, 548);
});

test("fails closed when every candidate has an unusable zero-height rect", () => {
  assert.throws(
    () =>
      pickActivationPoint(
        [
          {
            href: "https://oldschool.runescape.com/",
            text: "oldschool .runescape .com",
            rects: [
              {
                left: 467,
                top: 2078,
                right: 904,
                bottom: 2078,
                width: 437,
                height: 0,
                hitMatchesAnchor: true,
              },
            ],
          },
        ],
        { viewportWidth: 1080, viewportHeight: 1764 },
      ),
    /No visible clickable WebView rect/,
  );
});
