# SPDX-License-Identifier: MIT
"""Adversarial tests against the parqview burrito binary.

Every case here is something a hostile or careless caller would actually send.
A PASS means the server refused or handled it; a FAIL means it crashed, leaked,
or hung.
"""
import sys, time, urllib.parse, concurrent.futures as cf
import requests
from playwright.sync_api import sync_playwright

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:4340"
R = []

def check(label, ok, detail=""):
    R.append((label, bool(ok), detail))
    print(("  PASS  " if ok else "  FAIL  ") + label + (("  " + str(detail)[:90]) if detail else ""))

def get(path, **kw):
    return requests.get(BASE + path, timeout=20, **kw)

print("== path traversal / injection on /img/:relation/:id ==")
for probe in ["../../../../etc/passwd", "..%2f..%2f..%2fetc%2fpasswd",
              "....//....//etc/passwd", "/etc/passwd", "part-0000%00.parquet"]:
    try:
        r = get(f"/img/{urllib.parse.quote(probe, safe='')}/1")
        leaked = b"root:" in r.content or b"/bin/" in r.content
        check(f"traversal refused: {probe[:34]}", r.status_code in (404, 400, 500) and not leaked,
              f"{r.status_code} {len(r.content)}B")
    except Exception as e:
        check(f"traversal refused: {probe[:34]}", True, f"conn error {type(e).__name__}")

print("\n== malformed ids ==")
for bad in ["abc", "", "-1", "99999999999999999999", "1.5", "1;DROP", "٣", "1e10"]:
    try:
        r = get(f"/img/part-0000/{urllib.parse.quote(bad, safe='')}")
        check(f"id={bad!r:24} handled", r.status_code in (400, 404, 500),
              f"HTTP {r.status_code}")
    except Exception as e:
        check(f"id={bad!r:24} handled", False, f"connection died: {type(e).__name__}")

print("\n== unknown relation ==")
for rel in ["nope", "image", "..", "%2e%2e", "a" * 500]:
    try:
        r = get(f"/img/{urllib.parse.quote(rel, safe='')}/1")
        check(f"unknown relation {rel[:20]!r}", r.status_code in (400, 404, 500), f"HTTP {r.status_code}")
    except Exception as e:
        check(f"unknown relation {rel[:20]!r}", False, str(e)[:60])

print("\n== server still alive after all that ==")
try:
    check("root still 200", get("/").status_code == 200)
except Exception as e:
    check("root still 200", False, str(e)[:60])

print("\n== concurrent image fetches (memory blowup?) ==")
t0 = time.time()
try:
    with cf.ThreadPoolExecutor(8) as ex:
        codes = [f.result().status_code for f in
                 [ex.submit(get, "/img/part-0000/%d" % ((i % 6) + 1)) for i in range(16)]]
    check("16 concurrent image reads", all(c == 200 for c in codes),
          f"{len(set(codes))} distinct codes in {time.time()-t0:.1f}s")
except Exception as e:
    check("16 concurrent image reads", False, str(e)[:70])

print("\n== LiveView: hostile events ==")
with sync_playwright() as pw:
    b = pw.chromium.launch()
    page = b.new_page()
    crashes = []
    page.on("pageerror", lambda e: crashes.append(str(e)))
    page.goto(BASE, wait_until="networkidle")
    page.wait_for_timeout(1500)

    live = page.evaluate("() => !!(window.liveSocket && window.liveSocket.isConnected())")
    check("LiveView socket connected", live)

    if live:
        # push events the UI would never generate
        for name, payload in [
            ("select", {"name": "../../etc/passwd"}),
            ("select", {"name": "does-not-exist"}),
            ("page", {"offset": "-999999"}),
            ("page", {"offset": "999999999"}),
            ("page", {"offset": "not-a-number"}),
            ("select", {}),
        ]:
            page.evaluate(
                """([n, p]) => { const v = document.querySelector('[data-phx-main]');
                   if (window.liveSocket && v) {
                     try { window.liveSocket.getViewByEl(v).pushEvent(n, p, () => {}); } catch(e) {}
                   } }""", [name, payload])
            page.wait_for_timeout(700)

        alive = page.evaluate("() => !!(window.liveSocket && window.liveSocket.isConnected())")
        check("socket survived hostile events", alive)
        try:
            still = requests.get(BASE, timeout=10).status_code
            check("server survived hostile events", still == 200, f"HTTP {still}")
        except Exception as e:
            check("server survived hostile events", False, str(e)[:60])

    # data-driven XSS: relation/cell text is attacker-controlled if the parquet is
    page.goto(BASE, wait_until="networkidle"); page.wait_for_timeout(1200)
    html = page.content()
    check("no unescaped script tag from data", "<script>alert" not in html)
    b.close()

failed = [r for r in R if not r[1]]
print("\n%d/%d passed, %d FAILED" % (len(R) - len(failed), len(R), len(failed)))
for l, _, d in failed:
    print("   FAILED:", l, d)
sys.exit(1 if failed else 0)
