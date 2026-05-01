"""RSS scraper for curated Brazilian environmental news sources.

Fetches and normalises articles from 7 sources without requiring any paid API
key.  Each source is fetched independently; failures are logged and skipped so
that a single broken feed never blocks the others.

Returned article dicts share the same schema used by the rest of the news
pipeline (db_sqlite.bulk_upsert_news / news_sqlite.fetch_and_save_news):

    {
        "url":         str,   # canonical link (dedup key)
        "publishedAt": str,   # ISO-8601 UTC string
        "title":       str,
        "description": str,
        "source_name": str,
        "urlToImage":  str | None,
        "content":     str,   # empty – we only read RSS summaries
    }
"""

import asyncio
import logging
import re
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

import httpx

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Keyword relevance filter
# ---------------------------------------------------------------------------
# Articles from any source (RSS or NewsAPI) must contain at least one of these
# terms (case-insensitive, whole-word aware) in their title OR description to
# be considered relevant for Yvy's environmental focus.

_KEYWORDS_PT = {
    # Deforestation / fires
    "desmatamento", "queimada", "queimadas", "incêndio", "incêndios",
    "fogo", "fumaça", "brumagem",
    # Biomes / ecosystems
    "amazônia", "amazon", "cerrado", "pantanal", "mata atlântica",
    "caatinga", "pampa", "bioma", "biomas", "floresta", "florestas",
    "manguezal", "restinga",
    # Climate
    "clima", "climático", "climática", "mudança climática", "mudanças climáticas",
    "aquecimento global", "efeito estufa", "gases de efeito estufa",
    "carbono", "emissão", "emissões", "neutralidade", "descarbonização",
    "seca", "estiagem", "enchente", "alagamento", "inundação", "tempestade",
    "ciclone", "furacão", "el niño", "la niña",
    # Biodiversity / conservation
    "biodiversidade", "espécie ameaçada", "extinção", "fauna", "flora",
    "conservação", "área protegida", "unidade de conservação",
    "terra indígena", "território indígena", "ibama", "icmbio",
    # Pollution / environmental quality
    "poluição", "contaminação", "agrotóxico", "pesticida",
    "lixo", "resíduo", "reciclagem", "plástico", "microplástico",
    "qualidade do ar", "qualidade da água", "esgoto",
    # Sustainability / policy
    "sustentabilidade", "sustentável", "energia renovável", "energia solar",
    "energia eólica", "transição energética", "matriz energética",
    "prodes", "inpe", "terrabrasillis",
    # General environment
    "meio ambiente", "ambiental", "ecologia", "ecológico",
    "preservação", "reflorestamento", "áreas verdes",
}

_KEYWORDS_EN = {
    "deforestation", "wildfire", "wildland fire", "amazon", "cerrado",
    "pantanal", "atlantic forest", "biome", "forest", "mangrove",
    "climate", "climate change", "global warming", "greenhouse gas",
    "carbon", "emissions", "net zero", "decarbonization",
    "drought", "flood", "flooding", "hurricane", "cyclone",
    "el nino", "la nina", "biodiversity", "endangered species",
    "extinction", "conservation", "protected area", "indigenous land",
    "pollution", "contamination", "pesticide", "plastic", "microplastic",
    "air quality", "water quality", "sewage",
    "sustainability", "sustainable", "renewable energy", "solar energy",
    "wind energy", "energy transition", "environmental",
    "ecology", "ecological", "reforestation", "green areas",
    "ibama", "inpe",
}

# Pre-compiled pattern: matches any keyword as a substring (not full-word only,
# because Portuguese compound terms like "desmatamento" won't appear as isolated
# words in all contexts). We use word-boundary for English single-word terms
# and simple substring for compound PT terms.
_KW_PATTERN = re.compile(
    "|".join(re.escape(kw) for kw in sorted(
        _KEYWORDS_PT | _KEYWORDS_EN, key=len, reverse=True  # longest first
    )),
    re.IGNORECASE,
)


def is_relevant(article: dict) -> bool:
    """Return True if the article matches at least one environmental keyword."""
    text = " ".join(filter(None, [
        article.get("title", ""),
        article.get("description", ""),
    ]))
    return bool(_KW_PATTERN.search(text))



# ---------------------------------------------------------------------------
# Source catalogue
# ---------------------------------------------------------------------------

SOURCES = [
    {
        "name": "OEco",
        "url": "https://oeco.org.br/feed/",
        "format": "rss2",
    },
    {
        "name": "Observatório do Clima",
        "url": "https://www.oc.eco.br/feed/",
        "format": "rss2",
    },
    {
        "name": "Mongabay Brasil",
        "url": "https://brasil.mongabay.com/feed/",
        "format": "rss2",
    },
    {
        "name": "ClimaInfo",
        "url": "https://climainfo.org.br/feed/",
        "format": "rss2",
    },
    {
        "name": "Agência Brasil",
        "url": "https://agenciabrasil.ebc.com.br/meio-ambiente/feed/rss2",
        "format": "rss2",
    },
    {
        "name": "Envolverde",
        "url": "https://envolverde.com.br/feed/",
        "format": "rss2",
    },
    {
        "name": "G1 Meio Ambiente",
        "url": "https://g1.globo.com/rss/g1/meio-ambiente/",
        "format": "rss2",
    },
]

# Namespaces commonly used in WordPress / Globo RSS feeds
_NS = {
    "media":   "http://search.yahoo.com/mrss/",
    "content": "http://purl.org/rss/1.0/modules/content/",
    "dc":      "http://purl.org/dc/elements/1.1/",
    "atom":    "http://www.w3.org/2005/Atom",
}

_STRIP_HTML_RE = re.compile(r"<[^>]+>")
_WHITESPACE_RE = re.compile(r"\s+")


def _strip_html(text: str) -> str:
    """Remove HTML tags and collapse whitespace."""
    if not text:
        return ""
    text = _STRIP_HTML_RE.sub(" ", text)
    text = _WHITESPACE_RE.sub(" ", text)
    return text.strip()


def _parse_date(raw: str | None) -> str:
    """Parse RFC-2822 or ISO-8601 date strings to ISO-8601 UTC.

    Falls back to current UTC time if parsing fails.
    """
    if not raw:
        return datetime.now(timezone.utc).isoformat()
    raw = raw.strip()
    # Try RFC-2822 (standard for RSS2 <pubDate>)
    try:
        dt = parsedate_to_datetime(raw)
        return dt.astimezone(timezone.utc).isoformat()
    except Exception:
        pass
    # Try ISO-8601 variants
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %H:%M:%S"):
        try:
            dt = datetime.strptime(raw, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc).isoformat()
        except ValueError:
            pass
    logger.debug("Could not parse date %r, using now.", raw)
    return datetime.now(timezone.utc).isoformat()


def _text(element, tag: str, ns: str | None = None) -> str:
    """Safely get text from a child element, optionally using a namespace."""
    if element is None:
        return ""
    key = f"{{{_NS[ns]}}}{tag}" if ns else tag
    child = element.find(key)
    if child is None:
        return ""
    return (child.text or "").strip()


def _find_image(item: ET.Element) -> str | None:
    """Extract image URL from <enclosure>, <media:content>, or <media:thumbnail>."""
    # <enclosure url="..." type="image/..."/>
    enc = item.find("enclosure")
    if enc is not None:
        mime = enc.get("type", "")
        if mime.startswith("image"):
            return enc.get("url") or None

    # <media:content url="..." medium="image"/>
    for tag in (f"{{{_NS['media']}}}content", f"{{{_NS['media']}}}thumbnail"):
        el = item.find(tag)
        if el is not None:
            medium = el.get("medium", "")
            url = el.get("url", "")
            if url and (medium == "image" or re.search(r"\.(jpe?g|png|webp|gif)", url, re.I)):
                return url

    return None


def _parse_rss2(xml_bytes: bytes, source_name: str) -> list[dict]:
    """Parse an RSS 2.0 feed and return a list of normalised article dicts."""
    articles = []
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as exc:
        logger.warning("RSS XML parse error for %s: %s", source_name, exc)
        return []

    channel = root.find("channel")
    items = (channel or root).findall("item")

    for item in items:
        link = _text(item, "link") or _text(item, "guid")
        if not link or not link.startswith("http"):
            # Some feeds put the link as the tail of an <atom:link> element
            atom_link = item.find(f"{{{_NS['atom']}}}link")
            if atom_link is not None:
                link = atom_link.get("href", "")
        if not link:
            continue

        title = _strip_html(_text(item, "title"))
        # Prefer <content:encoded> over <description> for description text
        description = _strip_html(
            _text(item, "encoded", ns="content") or _text(item, "description")
        )
        # Trim description to 500 chars
        if len(description) > 500:
            description = description[:497] + "…"

        pub_date = _parse_date(_text(item, "pubDate") or _text(item, "date", ns="dc"))
        image_url = _find_image(item)

        articles.append(
            {
                "url": link.strip(),
                "publishedAt": pub_date,
                "title": title,
                "description": description,
                "source_name": source_name,
                "urlToImage": image_url,
                "content": "",
            }
        )

    return articles


# ---------------------------------------------------------------------------
# Per-source fetch
# ---------------------------------------------------------------------------

_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (compatible; Yvy-NewsBot/1.0; "
        "+https://github.com/samuelishida/yvy)"
    ),
    "Accept": "application/rss+xml, application/xml, text/xml, */*;q=0.8",
}


async def _fetch_source(client: httpx.AsyncClient, source: dict) -> list[dict]:
    """Fetch and parse a single RSS source. Returns [] on any error."""
    name = source["name"]
    url = source["url"]
    try:
        resp = await client.get(url, headers=_HEADERS, timeout=httpx.Timeout(20.0),
                                follow_redirects=True)
        if resp.status_code != 200:
            logger.warning(
                "RSS fetch returned HTTP %d for %s (%s)",
                resp.status_code, name, url,
            )
            return []
        articles = _parse_rss2(resp.content, name)
        logger.info(
            "RSS scrape OK: %s → %d articles", name, len(articles),
            extra={"event": "rss_fetch_ok", "details": {"source": name, "count": len(articles)}},
        )
        return articles
    except httpx.TimeoutException:
        logger.warning("RSS fetch timed out for %s (%s)", name, url)
    except httpx.RequestError as exc:
        logger.warning("RSS fetch request error for %s: %s", name, exc)
    except Exception as exc:
        logger.error("Unexpected error fetching %s: %s", name, exc, exc_info=True)
    return []


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

async def fetch_all_sources(
    client: httpx.AsyncClient | None = None,
    max_per_source: int = 20,
) -> list[dict]:
    """Fetch all configured sources concurrently.

    Args:
        client: Optional shared httpx.AsyncClient. If None a temporary one is
                created and closed after use.
        max_per_source: Maximum articles to keep per source (newest first).

    Returns:
        Deduplicated list of article dicts sorted newest-first.
    """
    own_client = client is None
    if own_client:
        client = httpx.AsyncClient(timeout=httpx.Timeout(20.0))

    try:
        tasks = [_fetch_source(client, src) for src in SOURCES]
        results = await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        if own_client:
            await client.aclose()

    seen_urls: set[str] = set()
    all_articles: list[dict] = []

    for batch in results:
        if isinstance(batch, Exception):
            logger.error("Unexpected gather exception: %s", batch)
            continue
        # Newest-first within each source, then cap
        batch_sorted = sorted(batch, key=lambda a: a["publishedAt"], reverse=True)
        for article in batch_sorted[:max_per_source]:
            url = article.get("url", "")
            if url and url not in seen_urls:
                seen_urls.add(url)
                all_articles.append(article)

    # Final global sort: newest first
    all_articles.sort(key=lambda a: a["publishedAt"], reverse=True)
    logger.info(
        "RSS scrape complete: %d unique articles from %d sources.",
        len(all_articles), len(SOURCES),
        extra={"event": "rss_scrape_complete", "details": {"total": len(all_articles)}},
    )
    return all_articles
