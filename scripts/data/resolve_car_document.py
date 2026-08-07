#!/usr/bin/env python3
"""Resolve rural-property documents → CAR receipt number(s) (cod_imovel).

The official CAR public consultation (https://consultapublica.car.gov.br) lets
you search an imóvel by CPF/CNPJ do titular, SNCR, or matrícula. This script
calls its JSON search endpoint and prints the matching receipt number(s), which
can then be fed to `/api/car/prodes?cod_imovel=` for PRODES verification.

Usage:
    python3 scripts/data/resolve_car_document.py --cpf 12345678901
    python3 scripts/data/resolve_car_document.py --cnpj 12345678000199
    python3 scripts/data/resolve_car_document.py --sncr 1234567
    python3 scripts/data/resolve_car_document.py --matricula 12345

Output: one cod_imovel per line (receipt numbers).
Exit codes: 0 = found, 1 = not found / API error, 2 = usage error.

NOTE: the consultation form is captcha-gated for browsers, but the JSON search
endpoint used by the SPA is scriptable. Verify the exact request shape on first
run against https://consultapublica.car.gov.br (network tab) and adjust
SEARCH_URL / payload if INPE changes it. Fallback when the API is down or
captcha blocks: have the user paste the receipt number directly.
"""
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

SEARCH_URL = "https://consultapublica.car.gov.br/publico/imoveis/consulta"
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) Yvy/1.0"


def _strip_digits(value: str) -> str:
    return re.sub(r"[^0-9]", "", value or "")


def _request(payload: dict) -> list:
    """POST the search payload; return the list of matching imóveis."""
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        SEARCH_URL,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
            "Referer": "https://consultapublica.car.gov.br/publico/imoveis/index",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    parsed = json.loads(body)
    if isinstance(parsed, list):
        return parsed
    if isinstance(parsed, dict):
        # The SPA returns {results: [...]} or similar wrappers — unpack defensively.
        for key in ("results", "imoveis", "data", "content"):
            if isinstance(parsed.get(key), list):
                return parsed[key]
    return []


def resolve(documento: str, tipo: str) -> list:
    """Resolve a document to CAR receipt numbers.

    tipo ∈ {cpf, cnpj, sncr, matricula}. Returns a list of cod_imovel strings.
    """
    key_map = {"cpf": "cpfCnpj", "cnpj": "cpfCnpj", "sncr": "sncr", "matricula": "matricula"}
    payload = {key_map[tipo]: _strip_digits(documento)}
    if not payload[key_map[tipo]]:
        raise ValueError(f"invalid {tipo}: {documento!r}")

    results = _request(payload)
    cods = []
    for r in results:
        if not isinstance(r, dict):
            continue
        cod = r.get("codImovel") or r.get("cod_imovel") or r.get("codigoImovel")
        if cod:
            cods.append(str(cod).strip())
    return cods


def main() -> None:
    args = sys.argv[1:]
    tipo = None
    valor = None
    for i, a in enumerate(args):
        if a in ("--cpf", "--cnpj", "--sncr", "--matricula"):
            tipo = a[2:]
            if i + 1 < len(args):
                valor = args[i + 1]
            break

    if not tipo or not valor:
        print(__doc__)
        sys.exit(2)

    try:
        cods = resolve(valor, tipo)
    except (urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"ERROR: CAR consultation API unavailable: {exc}", file=sys.stderr)
        print("Fallback: paste the CAR receipt number directly into /api/car/prodes?cod_imovel=", file=sys.stderr)
        sys.exit(1)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(2)

    if not cods:
        print(f"No CAR imóvel found for {tipo} {valor}", file=sys.stderr)
        sys.exit(1)

    for c in cods:
        print(c)


if __name__ == "__main__":
    main()
