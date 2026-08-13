#!/usr/bin/env python3
"""Render a professional risk-intelligence PDF report from a context JSON.

The context JSON is produced by the Lua backend (routes/risk.lua
`build_report_context`) and passed as a file path. This script renders a
branded multi-page PDF (Yvy) with identification, events, overlaps, history,
evidence, and a static map — the audit trail for compliance/EUDR.

Sections (plan: car-risk-expansion, Inc 3):
  P1 capa, P2 executive summary, P3 identificação cadastral, P4 eventos,
  P5 sobreposições + mapa estático, P6 histórico/tendência, P7 recomendação,
  P8 evidências.

Usage:
    python3 scripts/data/render_risk_report.py <context.json> <out.pdf>
"""
import json
import sys
from pathlib import Path

try:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import mm
    from reportlab.platypus import (Image, Paragraph, SimpleDocTemplate,
                                    Spacer, Table, TableStyle)
except ImportError:
    print("ERROR: reportlab not installed — add to scripts/requirements.txt "
          "and pip install", file=sys.stderr)
    sys.exit(1)

BRAND = colors.HexColor("#00875A")
INK = colors.HexColor("#1A1A1A")
INK_MUTED = colors.HexColor("#666666")
CANVAS = colors.HexColor("#FFFFFF")
SURFACE = colors.HexColor("#F5F7F5")
SURFACE_ALT = colors.HexColor("#EEF1EE")
BORDER = colors.HexColor("#D0D5D0")

LEVEL_COLORS = {
    "alto": colors.HexColor("#C62828"),
    "medio": colors.HexColor("#E65100"),
    "baixo": colors.HexColor("#00875A"),
}
LEVEL_BG = {
    "alto": colors.HexColor("#FFEBEE"),
    "medio": colors.HexColor("#FFF3E0"),
    "baixo": colors.HexColor("#E8F5E9"),
}


def _styles():
    styles = getSampleStyleSheet()
    return {
        "title": ParagraphStyle(
            "TitleX", parent=styles["Title"], textColor=INK, fontSize=20,
            spaceAfter=4 * mm,
        ),
        "h2": ParagraphStyle(
            "H2X", parent=styles["Heading2"], textColor=BRAND, fontSize=13,
            spaceBefore=6 * mm, spaceAfter=3 * mm,
        ),
        "body": ParagraphStyle(
            "BodyX", parent=styles["BodyText"], textColor=INK, fontSize=10,
            leading=14,
        ),
        "muted": ParagraphStyle(
            "MutedX", parent=styles["BodyText"], textColor=INK_MUTED, fontSize=9,
            leading=12,
        ),
    }


def _section_table(rows, col_widths):
    t = Table(rows, colWidths=col_widths)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), SURFACE),
        ("TEXTCOLOR", (0, 0), (-1, 0), BRAND),
        ("TEXTCOLOR", (0, 1), (-1, -1), INK),
        ("GRID", (0, 0), (-1, -1), 0.5, BORDER),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTNAME", (0, 1), (-1, -1), "Helvetica"),
        ("FONTSIZE", (0, 0), (-1, -1), 9),
        ("TOPPADDING", (0, 0), (-1, -1), 3 * mm),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3 * mm),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [CANVAS, SURFACE_ALT]),
    ]))
    return t


def _iter_polys(geom):
    """Yield Polygon objects from a Polygon or MultiPolygon."""
    if geom.geom_type == "Polygon":
        yield geom
    elif geom.geom_type == "MultiPolygon":
        for p in geom.geoms:
            yield p


def _decode_geom(g):
    if not g:
        return None
    try:
        from shapely.geometry import shape
        return shape(json.loads(g))
    except Exception:
        pass
    try:
        from shapely import wkt
        return wkt.loads(g)
    except Exception:
        return None


def _render_static_map(context, out_png):
    """Render the P5 static map (property + alerts) to a PNG, or None.

    Uses matplotlib + Shapely (offline, no tile fetch). Returns the PNG path,
    or None if matplotlib is missing or no geometry exists.
    """
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return None

    prop_geom = context.get("geometries", {}).get("property_geom")
    alert_geoms = context.get("geometries", {}).get("alert_geoms", [])
    if not prop_geom and not alert_geoms:
        return None

    fig, ax = plt.subplots(figsize=(6, 5), facecolor="#FFFFFF")
    ax.set_facecolor("#F5F7F5")

    prop = _decode_geom(prop_geom)
    if prop is not None:
        for poly in _iter_polys(prop):
            xs, ys = poly.exterior.xy
            ax.plot(xs, ys, color="#00875A", linewidth=1.5, label="Imóvel")

    for g in alert_geoms:
        geom = _decode_geom(g)
        if geom is not None:
            for poly in _iter_polys(geom):
                xs, ys = poly.exterior.xy
                ax.fill(xs, ys, color="#C62828", alpha=0.4)
                ax.plot(xs, ys, color="#C62828", linewidth=1)

    ax.set_aspect("equal")
    ax.axis("off")
    ax.legend(loc="upper right", facecolor="#FFFFFF", edgecolor="#D0D5D0",
              labelcolor="#1A1A1A")
    fig.tight_layout()
    fig.savefig(out_png, dpi=120, facecolor="#FFFFFF")
    plt.close(fig)
    return out_png


def render_report(context, out_path):
    doc = SimpleDocTemplate(
        str(out_path), pagesize=A4,
        leftMargin=18 * mm, rightMargin=18 * mm,
        topMargin=18 * mm, bottomMargin=18 * mm,
        title="Yvy Risk Intelligence Report",
        author="Yvy",
    )
    st = _styles()
    score = context.get("score") or {}
    level = score.get("level", "baixo")
    level_color = LEVEL_COLORS.get(level, BRAND)
    story = []

    # ── P1 Capa ──────────────────────────────────────────────────────────────
    story.append(Paragraph("Yvy Risk Intelligence", st["title"]))
    story.append(Paragraph(
        "Laudo de risco por propriedade — due diligence / EUDR", st["muted"]))
    story.append(Spacer(1, 4 * mm))

    score_val = int(score.get("score", 0))
    level_bg = LEVEL_BG.get(level, SURFACE)
    score_table = Table(
        [[Paragraph("SCORE DE RISCO", st["h2"]),
          Paragraph("<font color='#%s' size='28'><b>%d</b>/100</font>"
                    % (level_color.hexval()[2:], score_val), st["body"])]],
        colWidths=[90 * mm, 60 * mm],
    )
    score_table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), level_bg),
        ("BOX", (0, 0), (-1, -1), 1, BORDER),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("TOPPADDING", (0, 0), (-1, -1), 6 * mm),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6 * mm),
    ]))
    story.append(score_table)
    story.append(Spacer(1, 3 * mm))
    story.append(Paragraph("Nível: <b>%s</b>" % level.upper(), st["body"]))
    story.append(Spacer(1, 2 * mm))
    story.append(Paragraph("Recomendação: %s" % score.get("recommendation", ""),
                           st["body"]))
    story.append(Spacer(1, 4 * mm))

    # ── P2 Executive summary ─────────────────────────────────────────────────
    story.append(Paragraph("Resumo executivo", st["h2"]))
    prop = context.get("property") or {}
    summary_lines = []
    if prop.get("cod_imovel"):
        summary_lines.append("Imóvel: <b>%s</b>" % prop["cod_imovel"])
    if prop.get("municipio"):
        summary_lines.append("Município: %s / %s" % (prop.get("municipio", ""),
                                                     prop.get("uf", "")))
    if prop.get("area_ha"):
        summary_lines.append("Área cadastral: %.1f ha" % float(prop["area_ha"]))
    if not summary_lines:
        summary_lines.append("Identificação cadastral indisponível.")
    for line in summary_lines:
        story.append(Paragraph(line, st["body"]))
    story.append(Spacer(1, 3 * mm))

    # ── P3 Identificação cadastral ──────────────────────────────────────────
    story.append(Paragraph("Identificação cadastral", st["h2"]))
    if prop.get("cod_imovel"):
        rows = [["Campo", "Valor"],
                ["Código CAR", prop.get("cod_imovel", "")],
                ["UF", prop.get("uf", "")],
                ["Município", prop.get("municipio", "")],
                ["Área (ha)", "%.1f" % float(prop.get("area_ha") or 0)]]
        story.append(_section_table(rows, [50 * mm, 100 * mm]))
    else:
        story.append(Paragraph("Identificação cadastral indisponível (property "
                               "não é um CAR).", st["muted"]))
    story.append(Spacer(1, 3 * mm))

    # ── P4 Eventos ──────────────────────────────────────────────────────────
    story.append(Paragraph("Eventos de desmatamento", st["h2"]))
    alerts = context.get("alerts") or []
    if alerts:
        rows = [["Código", "Área (ha)", "Bioma", "UF", "Detecção"]]
        for a in alerts[:20]:
            rows.append([
                str(a.get("alert_code", "")),
                "%.1f" % float(a.get("area_ha") or 0),
                str(a.get("biome", "")),
                str(a.get("state", "")),
                str(a.get("data_deteccao", "")),
            ])
        story.append(_section_table(rows, [40 * mm, 25 * mm, 35 * mm, 20 * mm,
                                           30 * mm]))
    else:
        story.append(Paragraph("Sem alertas recentes.", st["muted"]))
    story.append(Spacer(1, 3 * mm))

    # ── P5 Sobreposições + mapa estático ─────────────────────────────────────
    story.append(Paragraph("Sobreposições e mapa", st["h2"]))
    protected = context.get("protected") or []
    if protected:
        rows = [["Tipo", "Nome", "Sobreposição"]]
        for p in protected[:20]:
            rows.append([
                str(p.get("type", "")),
                str(p.get("name", "")),
                "%.1f%%" % (float(p.get("overlap_pct", p.get("pct", 0)))),
            ])
        story.append(_section_table(rows, [40 * mm, 80 * mm, 30 * mm]))
    else:
        story.append(Paragraph("Sem sobreposição com UC/TI.", st["muted"]))
    story.append(Spacer(1, 3 * mm))

    map_png = "/tmp/yvy_risk_map_%s.png" % (context.get("property_id") or "x")
    if _render_static_map(context, map_png):
        try:
            story.append(Image(map_png, width=120 * mm, height=100 * mm))
        except Exception:
            story.append(Paragraph("Mapa indisponível.", st["muted"]))
    else:
        story.append(Paragraph("Geometria indisponível — mapa não gerado.",
                               st["muted"]))
    story.append(Spacer(1, 3 * mm))

    # ── P6 Histórico / tendência ─────────────────────────────────────────────
    story.append(Paragraph("Histórico / tendência", st["h2"]))
    history = context.get("history") or []
    if history:
        rows = [["Data", "Score", "Nível"]]
        for h in history[:20]:
            rows.append([str(h.get("computed_at", "")),
                         str(h.get("score", "")),
                         str(h.get("level", ""))])
        story.append(_section_table(rows, [60 * mm, 40 * mm, 50 * mm]))
    else:
        story.append(Paragraph("Sem histórico de scores anteriores.",
                               st["muted"]))
    story.append(Spacer(1, 3 * mm))

    # ── P7 Recomendação ──────────────────────────────────────────────────────
    story.append(Paragraph("Recomendação", st["h2"]))
    story.append(Paragraph(score.get("recommendation", ""), st["body"]))
    story.append(Spacer(1, 3 * mm))

    # ── P8 Evidências ────────────────────────────────────────────────────────
    story.append(Paragraph("Evidências", st["h2"]))
    factors = context.get("factors") or []
    if factors:
        rows = [["Fator", "Peso", "Valor"]]
        for f in factors:
            rows.append([
                str(f.get("name", "")),
                "%.0f%%" % (float(f.get("weight", 0)) * 100),
                "%.0f%%" % (float(f.get("value", 0)) * 100),
            ])
        story.append(_section_table(rows, [70 * mm, 40 * mm, 40 * mm]))
    else:
        story.append(Paragraph("Sem fatores de risco.", st["muted"]))
    story.append(Spacer(1, 3 * mm))

    embargoes = context.get("embargoes") or []
    if embargoes:
        story.append(Paragraph("Embargos IBAMA", st["h2"]))
        rows = [["Número", "Data", "UF", "Município"]]
        for e in embargoes[:20]:
            rows.append([str(e.get("numero", "")), str(e.get("data", "")),
                         str(e.get("uf", "")), str(e.get("municipio", ""))])
        story.append(_section_table(rows, [50 * mm, 30 * mm, 20 * mm, 50 * mm]))
    else:
        story.append(Paragraph("Sem embargo ativo.", st["muted"]))
    story.append(Spacer(1, 3 * mm))

    sinaflor_list = context.get("sinaflor") or []
    if sinaflor_list:
        story.append(Paragraph("Autorização de supressão (Sinaflor)", st["h2"]))
        rows = [["Número", "Modo", "Início", "Fim"]]
        for s in sinaflor_list[:20]:
            rows.append([str(s.get("nro", "")), str(s.get("modo", "")),
                         str(s.get("data_inicio", "")),
                         str(s.get("data_fim", ""))])
        story.append(_section_table(rows, [50 * mm, 30 * mm, 35 * mm, 35 * mm]))
    story.append(Spacer(1, 4 * mm))

    story.append(Paragraph(
        "Gerado por Yvy em %s. Este laudo é um artefato de auditoria "
        "server-side." % score.get("computed_at", ""), st["muted"]))

    doc.build(story)
    return True


def main():
    if len(sys.argv) < 3:
        print("usage: render_risk_report.py <context.json> <out.pdf>",
              file=sys.stderr)
        sys.exit(1)
    context_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    if not context_path.exists():
        print("ERROR: context json not found: %s" % context_path, file=sys.stderr)
        sys.exit(1)
    with open(context_path, "r", encoding="utf-8") as f:
        context = json.load(f)
    try:
        render_report(context, out_path)
    except Exception as exc:  # noqa: BLE001 - write .fail marker, exit non-zero
        print("ERROR: render failed: %s" % exc, file=sys.stderr)
        out_path.with_suffix(".fail").write_text("render failed\n", encoding="utf-8")
        sys.exit(1)
    # Sidecar completion marker: the Lua status endpoint flips running→ready
    # when this file appears. Written only after a successful render.
    out_path.with_suffix(".done").write_text("ok\n", encoding="utf-8")
    print("PDF written to %s" % out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
