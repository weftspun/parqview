# SPDX-License-Identifier: MIT
"""End-to-end test of the parqview LiveView against real Parquet relations."""
import sys, json
from playwright.sync_api import sync_playwright, expect

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:4330"
results = []

def check(label, cond, detail=""):
    results.append((label, bool(cond), detail))
    print(("  PASS  " if cond else "  FAIL  ") + label + (("  " + str(detail)) if detail else ""))

with sync_playwright() as pw:
    b = pw.chromium.launch()
    page = b.new_page(viewport={"width": 1600, "height": 1000})
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)

    page.goto(BASE, wait_until="networkidle")
    check("page loads", page.title() is not None, page.title())

    # sidebar lists relations
    buttons = page.locator("aside button")
    n = buttons.count()
    check("sidebar lists relations", n > 0, f"{n} relations")

    # A static [data-phx-main] attribute proves nothing: the socket must actually
    # be open, or every phx-click is silently inert.
    page.wait_for_timeout(1500)
    connected = page.evaluate("""() => {
        const el = document.querySelector('[data-phx-main]');
        return !!(el && el.classList.contains('phx-connected') === false
                  ? window.liveSocket && window.liveSocket.isConnected()
                  : window.liveSocket && window.liveSocket.isConnected());
    }""")
    check("LiveView socket CONNECTED", connected)

    # click through to a tabular relation and confirm rows render
    # select by exact label, not by parsed-text index: whitespace differs
    # between dev and a prod release and silently shifts the index
    def rel_button(page, name):
        return page.locator(f'aside button:has(span:text-is("{name}"))').first

    names = [buttons.nth(i).inner_text().split("\n")[0].strip() for i in range(n)]
    # first non-image relation, whatever the dataset happens to be called
    tabular = next((x for x in names if not x.startswith("part-")), None)
    if tabular:
        rel_button(page, tabular).click()
        page.wait_for_selector("table tbody tr", timeout=5000)
        rows = page.locator("table tbody tr").count()
        cols = page.locator("table thead th").count()
        check(f"{tabular} table renders", rows > 0 and cols > 0, f"{rows} rows x {cols} cols")
        first = page.locator("table tbody tr").first.inner_text()
        check("cell values present", len(first.strip()) > 0, first.replace("\t", " | ")[:50])

    # image relation renders a real thumbnail grid
    img_rel = next((x for x in names if x.startswith("part-")), None)
    if img_rel:
        rel_button(page, img_rel).click()
        page.wait_for_selector("figure img", timeout=8000)
        imgs = page.locator("figure img")
        check("image grid renders", imgs.count() > 0, f"{imgs.count()} thumbnails")
        # the browser must actually decode them, not just emit <img> tags
        page.wait_for_timeout(2500)
        decoded = page.evaluate("""() => Array.from(document.querySelectorAll('figure img'))
            .filter(i => i.complete && i.naturalWidth > 0).length""")
        check("thumbnails decode in browser", decoded > 0, f"{decoded} decoded")
        dims = page.evaluate("""() => { const i = document.querySelector('figure img');
            return i ? [i.naturalWidth, i.naturalHeight] : null }""")
        check("image has real dimensions", dims and dims[0] > 100, dims)

    # pagination
    nxt = page.locator("button", has_text="next").first
    if nxt.is_visible() and nxt.is_enabled():
        before = page.locator("main span.px-2").first.inner_text()
        nxt.click(); page.wait_for_timeout(1200)
        after = page.locator("main span.px-2").first.inner_text()
        check("pagination advances", before != after, f"{before} -> {after}")

    check("no JS errors", not errors, errors[:2])
    page.screenshot(path="parqview_grid.png", full_page=False)
    b.close()

failed = [r for r in results if not r[1]]
print("\n%d/%d passed" % (len(results) - len(failed), len(results)))
sys.exit(1 if failed else 0)
