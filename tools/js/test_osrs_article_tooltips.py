#!/usr/bin/env python3
"""Original article tooltip chrome: wiki HTML contract, no gadget source."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "shared" / "js" / "osrs_article_tooltips.js"

THRALL_SNIPPET = """
<table class="wikitable">
  <tr>
    <td><span class="hidden js-tooltip-click" data-tooltip-name="38" style="display:none">38</span></td>
    <td class="outside-click">22.8 seconds</td>
  </tr>
  <tr>
    <td><span class="hidden js-tooltip-click" data-tooltip-name="57" style="display:none">57</span></td>
    <td>34.2 seconds</td>
  </tr>
</table>
<div class="hidden js-tooltip-wrapper" data-tooltip-limit-width="yes" data-tooltip-arrow-size="10" data-tooltip-for="38" data-tooltip-arrow="yes" style="display:none"><div class="js-tooltip-text">Required for Resurrect Lesser spells</div></div>
<div class="hidden js-tooltip-wrapper" data-tooltip-limit-width="yes" data-tooltip-arrow-size="10" data-tooltip-for="57" data-tooltip-arrow="yes" style="display:none"><div class="js-tooltip-text">Required for Resurrect Superior spells</div></div>
<p>Shared <span class="hidden js-tooltip-click" data-tooltip-name="38" style="display:none">?</span> marker.</p>
"""

FAKE_DOM = r"""
function FakeClassList(el) {
  this.el = el;
}
FakeClassList.prototype.contains = function (name) {
  return this.el._classes.has(name);
};
FakeClassList.prototype.add = function (name) {
  this.el._classes.add(name);
  this.el.className = Array.from(this.el._classes).join(' ');
};
FakeClassList.prototype.remove = function (name) {
  this.el._classes.delete(name);
  this.el.className = Array.from(this.el._classes).join(' ');
};
function parseClass(value) {
  return new Set(String(value || '').split(/\s+/).filter(Boolean));
}
function matches(el, selector) {
  if (!el || el.nodeType !== 1) return false;
  var attr = selector.match(/^([a-zA-Z0-9-]+)?(?:\.([a-zA-Z0-9_-]+))?(?:\[([a-zA-Z0-9-]+(?:="[^"]*")?)\])?$/);
  if (!attr) return false;
  if (attr[1] && String(el.tagName).toLowerCase() !== attr[1].toLowerCase()) return false;
  if (attr[2] && !el._classes.has(attr[2])) return false;
  if (attr[3]) {
    var eq = attr[3].match(/^([^=]+)(?:="([^"]*)")?$/);
    if (!eq) return false;
    if (eq[2] == null) return el.getAttribute(eq[1]) != null;
    return el.getAttribute(eq[1]) === eq[2];
  }
  if (!attr[1] && !attr[2] && !attr[3]) return false;
  return true;
}
function FakeEl(tag, owner) {
  this.tagName = String(tag || 'div').toUpperCase();
  this.nodeType = 1;
  this.ownerDocument = owner;
  this.parentNode = null;
  this.childNodes = [];
  this._attrs = {};
  this._classes = new Set();
  this.className = '';
  this.style = {};
  this.classList = new FakeClassList(this);
  this._listeners = {};
  this.textContent = '';
  this._rect = { left: 12, top: 40, right: 40, bottom: 56, width: 28, height: 16 };
}
FakeEl.prototype.getAttribute = function (name) {
  var key = String(name);
  if (key === 'class') return this.className;
  return this._attrs[key] == null ? null : this._attrs[key];
};
FakeEl.prototype.setAttribute = function (name, value) {
  var key = String(name);
  var val = String(value);
  if (key === 'class') {
    this._classes = parseClass(val);
    this.className = val;
    return;
  }
  this._attrs[key] = val;
};
FakeEl.prototype.hasAttribute = function (name) {
  return this.getAttribute(name) != null;
};
FakeEl.prototype.removeAttribute = function (name) {
  delete this._attrs[String(name)];
};
FakeEl.prototype.appendChild = function (child) {
  child.parentNode = this;
  this.childNodes.push(child);
  return child;
};
FakeEl.prototype.insertBefore = function (child, ref) {
  child.parentNode = this;
  var index = ref ? this.childNodes.indexOf(ref) : -1;
  if (index < 0) this.childNodes.push(child);
  else this.childNodes.splice(index, 0, child);
  return child;
};
Object.defineProperty(FakeEl.prototype, 'firstChild', {
  get: function () { return this.childNodes[0] || null; }
});
FakeEl.prototype.contains = function (node) {
  if (node === this) return true;
  return this.childNodes.some(function (child) {
    return child.contains && child.contains(node);
  });
};
FakeEl.prototype.closest = function (selector) {
  var node = this;
  while (node && node.nodeType === 1) {
    if (matches(node, selector)) return node;
    node = node.parentNode;
  }
  return null;
};
FakeEl.prototype.querySelectorAll = function (selector) {
  var out = [];
  function walk(node) {
    if (node.nodeType === 1 && matches(node, selector)) out.push(node);
    (node.childNodes || []).forEach(walk);
  }
  this.childNodes.forEach(walk);
  return out;
};
FakeEl.prototype.querySelector = function (selector) {
  return this.querySelectorAll(selector)[0] || null;
};
FakeEl.prototype.addEventListener = function (type, fn) {
  (this._listeners[type] || (this._listeners[type] = [])).push(fn);
};
FakeEl.prototype.dispatchEvent = function (event) {
  event.target = event.target || this;
  var node = this;
  while (node) {
    (node._listeners[event.type] || []).forEach(function (fn) { fn.call(node, event); });
    node = node.parentNode;
  }
  if (this.ownerDocument && this.ownerDocument._listeners[event.type]) {
    this.ownerDocument._listeners[event.type].forEach(function (fn) {
      fn.call(this.ownerDocument, event);
    }.bind(this));
  }
};
FakeEl.prototype.getBoundingClientRect = function () {
  return this._rect;
};
function parseHtml(html, doc) {
  var root = new FakeEl('body', doc);
  var re = /<(\/)?([a-zA-Z0-9]+)([^>]*)>|([^<]+)/g;
  var stack = [root];
  var m;
  while ((m = re.exec(html))) {
    if (m[4]) {
      stack[stack.length - 1].textContent += m[4];
      continue;
    }
    var tag = m[2].toLowerCase();
    if (m[1]) {
      if (stack.length > 1 && stack[stack.length - 1].tagName.toLowerCase() === tag) stack.pop();
      continue;
    }
    var el = new FakeEl(tag, doc);
    var attrs = m[3] || '';
    var am;
    var are = /([a-zA-Z0-9:-]+)(?:="([^"]*)")?/g;
    while ((am = are.exec(attrs))) {
      el.setAttribute(am[1], am[2] == null ? '' : am[2]);
    }
    stack[stack.length - 1].appendChild(el);
    if (!/\/\s*$/.test(attrs) && tag !== 'br') stack.push(el);
  }
  return root;
}
function makeDocument(html) {
  var doc = {
    nodeType: 9,
    readyState: 'complete',
    _listeners: {},
    documentElement: { clientWidth: 360, clientHeight: 640 },
    createElement: function (tag) { return new FakeEl(tag, doc); },
    addEventListener: function (type, fn) {
      (doc._listeners[type] || (doc._listeners[type] = [])).push(fn);
    }
  };
    doc.body = parseHtml(html, doc);
  doc.body.ownerDocument = doc;
  doc.querySelectorAll = function (selector) { return doc.body.querySelectorAll(selector); };
  doc.querySelector = function (selector) { return doc.body.querySelector(selector); };
  doc.dispatchEvent = function (event) {
    event.target = event.target || doc;
    (doc._listeners[event.type] || []).forEach(function (fn) { fn.call(doc, event); });
  };
  return doc;
}
"""


def eval_js(html: str, expr: str) -> object:
    script = (
        FAKE_DOM
        + "const api = require("
        + json.dumps(str(SCRIPT))
        + ");\n"
        + "const document = makeDocument("
        + json.dumps(html)
        + ");\n"
        + "const window = { document: document, innerWidth: 360, innerHeight: 640 };\n"
        + "global.window = window;\n"
        + "global.document = document;\n"
        + "const result = ("
        + expr
        + ");\n"
        + "process.stdout.write(JSON.stringify(result));\n"
    )
    raw = subprocess.check_output(["node", "-e", script], text=True)
    return json.loads(raw)


class OsrsArticleTooltipTests(unittest.TestCase):
    def test_source_is_original_and_not_a_gadget(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertTrue(SCRIPT.is_file())
        self.assertNotIn("ext.gadget", text)
        self.assertNotIn("MediaWiki:Gadget", text)
        self.assertNotIn("mw.loader", text)
        self.assertNotIn("gadget-tooltips", text)
        self.assertIn("js-tooltip-click", text)
        self.assertIn("data-tooltip-name", text)
        self.assertIn("data-tooltip-for", text)

    def test_boot_reveals_click_targets_and_keeps_wrappers_closed(self) -> None:
        result = eval_js(
            THRALL_SNIPPET,
            """(() => {
              api.boot(document);
              const clicks = document.querySelectorAll('.js-tooltip-click');
              const wraps = document.querySelectorAll('.js-tooltip-wrapper');
              return {
                clickCount: clicks.length,
                revealed: clicks.every((el) => !el.classList.contains('hidden') && el.style.display !== 'none'),
                wrappersHidden: wraps.every((el) => el.style.display === 'none' || el.classList.contains('hidden')),
                openName: api.openName(document)
              };
            })()""",
        )
        self.assertEqual(result["clickCount"], 3)
        self.assertTrue(result["revealed"])
        self.assertTrue(result["wrappersHidden"])
        self.assertIsNone(result["openName"])

    def test_click_opens_matching_wrapper_and_second_name_replaces_it(self) -> None:
        result = eval_js(
            THRALL_SNIPPET,
            """(() => {
              api.boot(document);
              const first = document.querySelector('.js-tooltip-click[data-tooltip-name="38"]');
              const second = document.querySelector('.js-tooltip-click[data-tooltip-name="57"]');
              first.dispatchEvent({ type: 'click', target: first, preventDefault: function () {}, stopPropagation: function () {} });
              const wrap38 = document.querySelector('.js-tooltip-wrapper[data-tooltip-for="38"]');
              const wrap57 = document.querySelector('.js-tooltip-wrapper[data-tooltip-for="57"]');
              const afterFirst = {
                openName: api.openName(document),
                text: wrap38.querySelector('.js-tooltip-text').textContent,
                firstHidden: api.isHidden(wrap38),
                secondHidden: api.isHidden(wrap57)
              };
              second.dispatchEvent({ type: 'click', target: second, preventDefault: function () {}, stopPropagation: function () {} });
              return {
                afterFirst,
                afterSecond: {
                  openName: api.openName(document),
                  firstHidden: api.isHidden(wrap38),
                  secondHidden: api.isHidden(wrap57)
                }
              };
            })()""",
        )
        self.assertEqual(result["afterFirst"]["openName"], "38")
        self.assertIn("Resurrect Lesser", result["afterFirst"]["text"])
        self.assertFalse(result["afterFirst"]["firstHidden"])
        self.assertTrue(result["afterFirst"]["secondHidden"])
        self.assertEqual(result["afterSecond"]["openName"], "57")
        self.assertTrue(result["afterSecond"]["firstHidden"])
        self.assertFalse(result["afterSecond"]["secondHidden"])

    def test_same_name_from_two_triggers_and_toggle_and_outside_click(self) -> None:
        result = eval_js(
            THRALL_SNIPPET,
            """(() => {
              api.boot(document);
              const clicks = document.querySelectorAll('.js-tooltip-click[data-tooltip-name="38"]');
              const outside = document.querySelector('.outside-click');
              clicks[0].dispatchEvent({ type: 'click', target: clicks[0], preventDefault: function () {}, stopPropagation: function () {} });
              const firstOpen = api.openName(document);
              clicks[1].dispatchEvent({ type: 'click', target: clicks[1], preventDefault: function () {}, stopPropagation: function () {} });
              const sharedStillOpen = api.openName(document);
              clicks[1].dispatchEvent({ type: 'click', target: clicks[1], preventDefault: function () {}, stopPropagation: function () {} });
              const toggled = api.openName(document);
              clicks[0].dispatchEvent({ type: 'click', target: clicks[0], preventDefault: function () {}, stopPropagation: function () {} });
              outside.dispatchEvent({ type: 'click', target: outside, preventDefault: function () {}, stopPropagation: function () {} });
              return { firstOpen, sharedStillOpen, toggled, afterOutside: api.openName(document) };
            })()""",
        )
        self.assertEqual(result["firstOpen"], "38")
        self.assertEqual(result["sharedStillOpen"], "38")
        self.assertIsNone(result["toggled"])
        self.assertIsNone(result["afterOutside"])

    def test_close_button_and_escape_hide_the_open_tooltip(self) -> None:
        html = THRALL_SNIPPET.replace(
            '<div class="js-tooltip-text">Required for Resurrect Lesser spells</div>',
            '<button type="button" class="js-tooltip-close" aria-label="Close">x</button><div class="js-tooltip-text">Required for Resurrect Lesser spells</div>',
        )
        result = eval_js(
            html,
            """(() => {
              api.boot(document);
              const click = document.querySelector('.js-tooltip-click[data-tooltip-name="38"]');
              click.dispatchEvent({ type: 'click', target: click, preventDefault: function () {}, stopPropagation: function () {} });
              const opened = api.openName(document);
              const close = document.querySelector('.js-tooltip-close');
              close.dispatchEvent({ type: 'click', target: close, preventDefault: function () {}, stopPropagation: function () {} });
              const afterClose = api.openName(document);
              click.dispatchEvent({ type: 'click', target: click, preventDefault: function () {}, stopPropagation: function () {} });
              document.dispatchEvent({ type: 'keydown', key: 'Escape', target: document, preventDefault: function () {} });
              return { opened, afterClose, afterEscape: api.openName(document) };
            })()""",
        )
        self.assertEqual(result["opened"], "38")
        self.assertIsNone(result["afterClose"])
        self.assertIsNone(result["afterEscape"])

    def test_platform_copies_keep_byte_parity(self) -> None:
        copies = [
            ROOT / "platforms" / "android" / "app" / "src" / "main" / "assets" / "web" / "osrs_article_tooltips.js",
            ROOT / "platforms" / "ios" / "osrswiki" / "Assets" / "web" / "osrs_article_tooltips.js",
        ]
        shared = SCRIPT.read_bytes()
        for copy in copies:
            self.assertTrue(copy.is_file(), copy)
            self.assertEqual(shared, copy.read_bytes(), f"{copy} drifted from {SCRIPT}")


if __name__ == "__main__":
    unittest.main()
