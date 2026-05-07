#!/usr/bin/env python
from __future__ import annotations

import argparse
import asyncio
import json
import random
import re
import sys
from urllib.parse import urljoin

STEALTH_ARGS = [
    "--disable-gpu",
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--disable-extensions",
    "--disable-background-networking",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-breakpad",
    "--disable-default-apps",
    "--disable-hang-monitor",
    "--disable-popup-blocking",
    "--disable-renderer-backgrounding",
    "--disable-blink-features=AutomationControlled",
    "--disable-features=IsolateOrigins,site-per-process",
    "--window-size=1920,1080",
]

# Stealth init script — based on samuelishida/hardware-bot patterns.
# Spoofs navigator.webdriver, plugins, languages, hardware fingerprint,
# userAgentData, window.chrome.runtime, and Permissions API mock.
STEALTH_SCRIPT = """
Object.defineProperty(navigator, 'webdriver', { get: () => false });
Object.defineProperty(navigator, 'plugins', {
    get: () => [
        { name: 'Chrome PDF Plugin', filename: 'internal-pdf-viewer' },
        { name: 'Chrome PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai' },
        { name: 'Native Client', filename: 'internal-nacl-plugin' },
    ],
});
Object.defineProperty(navigator, 'language', { get: () => 'pt-BR' });
Object.defineProperty(navigator, 'languages', { get: () => ['pt-BR', 'pt', 'en-US', 'en'] });
Object.defineProperty(navigator, 'platform', { get: () => 'Win32' });
Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => 8 });
Object.defineProperty(navigator, 'deviceMemory', { get: () => 8 });
Object.defineProperty(navigator, 'maxTouchPoints', { get: () => 0 });
Object.defineProperty(navigator, 'userAgentData', {
    get: () => ({
        mobile: false,
        platform: 'Windows',
        brands: [
            { brand: 'Chromium', version: '131' },
            { brand: 'Google Chrome', version: '131' },
            { brand: 'Not_A Brand', version: '24' }
        ]
    })
});
window.chrome = window.chrome || {};
window.chrome.runtime = window.chrome.runtime || {
    id: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
    connect: () => ({}),
    sendMessage: () => {},
    getURL: () => '',
    getManifest: () => ({ version: '1.0', name: 'Google Chrome' }),
};
const originalQuery = window.navigator.permissions && window.navigator.permissions.query;
if (originalQuery) {
  window.navigator.permissions.query = (parameters) => (
    parameters && parameters.name === 'notifications'
      ? Promise.resolve({ state: Notification.permission })
      : originalQuery(parameters)
  );
}
"""

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
]

VIEWPORTS = [
    {"width": 1920, "height": 1080},
    {"width": 1366, "height": 768},
    {"width": 1536, "height": 864},
    {"width": 1440, "height": 900},
]

BLOCK_PATTERNS = (
    "attention required",
    "verify you are human",
    "bot verification",
    "/cdn-cgi/challenge",
    "cf-chl-",
    "<title>access denied",
)

IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".avif", ".gif")


def challenge_detected(text: str) -> bool:
    lowered = (text or "").lower()
    return any(pat in lowered for pat in BLOCK_PATTERNS)


def is_bad_image_url(url: str) -> bool:
    lowered = (url or "").lower().rstrip("/")
    path = lowered.split("?", 1)[0]
    return (
        lowered.endswith(("/none", "/null", "/undefined"))
        or not any(ext in path for ext in IMAGE_EXTS)
        or lowered.endswith(".svg")
        or lowered.endswith(".html")
        or lowered.endswith(".ghtml")
        or "logo" in lowered
        or "icon" in lowered
        or "pixel" in lowered
        or "1x1" in lowered
    )


def extract_meta_image(html: str, base_url: str = "") -> str | None:
    patterns = [
        r'property=["\']og:image["\']\s+content=["\']([^"\']+)["\']',
        r'content=["\']([^"\']+)["\']\s+property=["\']og:image["\']',
        r'name=["\']twitter:image["\']\s+content=["\']([^"\']+)["\']',
        r'content=["\']([^"\']+)["\']\s+name=["\']twitter:image["\']',
        r'background-image\s*:\s*url\((["\']?)([^"\')]+)\1\)',
        r'<img[^>]+src=["\']([^"\']+)["\']',
        r'<img[^>]+data-src=["\']([^"\']+)["\']',
    ]
    for pattern in patterns:
        match = re.search(pattern, html, re.I)
        if match:
            candidate = match.group(2) if match.lastindex and match.lastindex >= 2 else match.group(1)
            if candidate and not candidate.startswith("data:"):
                image_url = urljoin(base_url, candidate)
                if not is_bad_image_url(image_url):
                    return image_url

    srcset = re.search(r'<img[^>]+srcset=["\']([^"\']+)["\']', html, re.I)
    if srcset:
        first = srcset.group(1).split(",")[0].strip().split(" ")[0]
        if first and not first.startswith("data:"):
            image_url = urljoin(base_url, first)
            if not is_bad_image_url(image_url):
                return image_url

    return None


def extract_title(html: str) -> str | None:
    match = re.search(r"<title[^>]*>(.*?)</title>", html or "", re.I | re.S)
    if not match:
        return None
    return re.sub(r"\s+", " ", match.group(1)).strip() or None


async def extract_dom_image(page) -> str | None:
    candidates = await page.evaluate(
        """() => {
          const out = [];
          const add = (value) => { if (value) out.push(value); };
          document.querySelectorAll('meta[property="og:image"], meta[property="og:image:url"], meta[name="twitter:image"], meta[name="twitter:image:src"], meta[itemprop="image"]')
            .forEach((el) => add(el.content || el.getAttribute('content')));
          document.querySelectorAll('[style*="background-image"]')
            .forEach((el) => {
              const inline = el.getAttribute('style') || '';
              const match = inline.match(/background-image\\s*:\\s*url\\((['"]?)(.*?)\\1\\)/i);
              add(match && match[2]);
            });
          document.querySelectorAll('img').forEach((img) => {
            add(img.currentSrc || img.src);
            add(img.dataset && (img.dataset.src || img.dataset.lazySrc || img.dataset.original));
            if (img.srcset) {
              img.srcset.split(',').forEach((part) => add(part.trim().split(/\\s+/)[0]));
            }
          });
          return out;
        }"""
    )
    for candidate in candidates:
        image_url = urljoin(page.url, candidate)
        if not is_bad_image_url(image_url):
            return image_url
    return None


async def run(url: str, mode: str) -> dict:
    try:
        from playwright.async_api import async_playwright
    except Exception as exc:  # pragma: no cover
        return {"ok": False, "error": f"playwright import failed: {exc}"}

    ua = random.choice(USER_AGENTS)
    vp = random.choice(VIEWPORTS)
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True, args=STEALTH_ARGS)
        context = await browser.new_context(
            user_agent=ua,
            locale="pt-BR",
            timezone_id="America/Sao_Paulo",
            viewport=vp,
            device_scale_factor=1,
            color_scheme="light",
            reduced_motion="no-preference",
        )
        await context.add_init_script(STEALTH_SCRIPT)

        page = await context.new_page()
        await page.set_extra_http_headers({
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.8",
            "Connection": "keep-alive",
            "Upgrade-Insecure-Requests": "1",
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-User": "?1",
            "Cache-Control": "max-age=0",
        })

        async def route_handler(route):
            req = route.request
            resource_type = req.resource_type
            if resource_type in {"font", "media"}:
                await route.abort()
                return
            await route.continue_()

        await page.route("**/*", route_handler)

        response = await page.goto(url, wait_until="domcontentloaded", timeout=45000)
        await page.wait_for_timeout(1500)

        response_text = ""
        if response is not None:
            try:
                response_text = await response.text()
            except Exception:
                response_text = ""

        page_html = await page.content()
        status = response.status if response is not None else 0
        body = response_text or page_html
        image = extract_meta_image(page_html, page.url) or await extract_dom_image(page)
        challenge = challenge_detected(body) or challenge_detected(page_html)
        if status == 200 and image:
            challenge = False

        result = {
            "ok": True,
            "status": status,
            "url": page.url,
            "body": body,
            "html": page_html,
            "title": extract_title(page_html),
            "image": image,
            "challenge": challenge,
        }

        await context.close()
        await browser.close()
        return result


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--mode", choices=("feed", "page"), default="feed")
    args = parser.parse_args()

    result = asyncio.run(run(args.url, args.mode))
    sys.stdout.write(json.dumps(result, ensure_ascii=False))
    sys.stdout.flush()
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
