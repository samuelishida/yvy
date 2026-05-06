#!/usr/bin/env python
from __future__ import annotations

import argparse
import asyncio
import json
import random
import re
import sys

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
    "--window-size=1920,1080",
]

STEALTH_SCRIPT = """
Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
Object.defineProperty(navigator, 'platform', { get: () => 'Win32' });
Object.defineProperty(navigator, 'language', { get: () => 'pt-BR' });
Object.defineProperty(navigator, 'languages', { get: () => ['pt-BR', 'pt', 'en-US', 'en'] });
Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => 8 });
Object.defineProperty(navigator, 'deviceMemory', { get: () => 8 });
Object.defineProperty(navigator, 'maxTouchPoints', { get: () => 0 });
window.chrome = window.chrome || { runtime: {} };
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
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
]

BLOCK_PATTERNS = (
    "captcha",
    "cloudflare",
    "attention required",
    "access denied",
    "forbidden",
    "verify you are human",
    "bot verification",
    "/cdn-cgi/challenge",
)


def challenge_detected(text: str) -> bool:
    lowered = (text or "").lower()
    return any(pat in lowered for pat in BLOCK_PATTERNS)


def extract_meta_image(html: str) -> str | None:
    patterns = [
        r'property=["\']og:image["\']\s+content=["\']([^"\']+)["\']',
        r'content=["\']([^"\']+)["\']\s+property=["\']og:image["\']',
        r'name=["\']twitter:image["\']\s+content=["\']([^"\']+)["\']',
        r'content=["\']([^"\']+)["\']\s+name=["\']twitter:image["\']',
        r'<img[^>]+src=["\']([^"\']+)["\']',
    ]
    for pattern in patterns:
        match = re.search(pattern, html, re.I)
        if match:
            candidate = match.group(1)
            if candidate and not candidate.startswith("data:"):
                return candidate
    return None


def extract_title(html: str) -> str | None:
    match = re.search(r"<title[^>]*>(.*?)</title>", html or "", re.I | re.S)
    if not match:
        return None
    return re.sub(r"\s+", " ", match.group(1)).strip() or None


async def run(url: str, mode: str) -> dict:
    try:
        from playwright.async_api import async_playwright
    except Exception as exc:  # pragma: no cover
        return {"ok": False, "error": f"playwright import failed: {exc}"}

    ua = random.choice(USER_AGENTS)
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True, args=STEALTH_ARGS)
        context = await browser.new_context(
            user_agent=ua,
            locale="pt-BR",
            timezone_id="America/Sao_Paulo",
            viewport={"width": 1920, "height": 1080},
            device_scale_factor=1,
            color_scheme="light",
        )
        await context.add_init_script(STEALTH_SCRIPT)

        page = await context.new_page()
        await page.set_extra_http_headers({
            "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.8",
            "Upgrade-Insecure-Requests": "1",
        })

        async def route_handler(route):
            req = route.request
            resource_type = req.resource_type
            if resource_type in {"font", "media"}:
                await route.abort()
                return
            if mode == "page" and resource_type == "image":
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

        result = {
            "ok": True,
            "status": status,
            "url": page.url,
            "body": body,
            "html": page_html,
            "title": extract_title(page_html),
            "image": extract_meta_image(page_html),
            "challenge": challenge_detected(body) or challenge_detected(page_html),
        }

        await context.close()
        await browser.close()
        return result


def main() -> int:
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
