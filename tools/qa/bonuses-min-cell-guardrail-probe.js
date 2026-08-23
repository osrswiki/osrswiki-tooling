/**
 * Task 8 / FirstViewportSettled — Abyssal whip bonuses crush guardrail.
 *
 * Evaluate in the article WebView AFTER FirstViewPainted body reveal.
 * Fail the Phase B intervention if ok === false (needle-thin cells).
 *
 * Floor: 28 CSS px min visible cell width (plan + protocol lock).
 */
(function () {
  var t = document.querySelector("table.infobox-bonuses");
  if (!t) return { ok: true, reason: "no-bonuses-table" };
  var cells = t.querySelectorAll("th,td");
  var minW = Infinity;
  cells.forEach(function (c) {
    var w = c.getBoundingClientRect().width;
    if (w > 0 && w < minW) minW = w;
  });
  if (minW === Infinity) {
    return { ok: true, reason: "no-positive-width-cells", minCellWidth: 0 };
  }
  return { ok: minW >= 28, minCellWidth: minW };
})();
