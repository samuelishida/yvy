// /politica — government-period comparator. Plan: politica-transparencia, Inc 4.
//
// Three period cards plus one proportional bar per period, so the same fact is
// shown twice (number + bar length). The "best" period is chosen by the metric's
// declared `direction` — never by narrative.

import React from 'react';
import { useI18n } from '../../i18n';
import { usePolitica } from './Politica';
import { SourceRef, formatMoney } from './politicaUi';
import { formatInt, formatPct, formatKm2 } from '../../utils/format';

function formatValue(kpi, v, lang) {
  if (kpi.unit === '%') return formatPct(v, lang);
  if (kpi.unit === 'km²') return formatKm2(Math.round(v), lang);
  if (kpi.unit === 'R$') return `${lang === 'en' ? 'BRL ' : 'R$ '}${formatInt(Math.round(v), lang)}`;
  if (kpi.unit === 'R$ milhões') return formatMoney(v * 1e6, lang);
  if (kpi.unit === 'índice') return Number(v).toLocaleString(lang === 'en' ? 'en-US' : 'pt-BR', { minimumFractionDigits: 3, maximumFractionDigits: 3 });
  return formatInt(v, lang);
}

// Which compare entry is "best" given the KPI's direction. `lower_is_better` →
// the smallest; `higher_is_better` → the largest. Returns the index, or -1.
function bestIndex(kpi) {
  if (!kpi.compare || kpi.compare.length === 0) return -1;
  const vals = kpi.compare.map((c) => c.value);
  const target = kpi.direction === 'higher_is_better' ? Math.max(...vals) : Math.min(...vals);
  return vals.indexOf(target);
}

function PeriodCard({ label, value, best, worst, barPct, sourceIds, sources, kpi, lang }) {
  const { t } = useI18n();
  return (
    <div
      className="stat-card"
      style={{
        flexDirection: 'column',
        alignItems: 'stretch',
        borderColor: best ? 'rgba(74, 222, 128, 0.5)' : undefined,
      }}
    >
      <p className="stat-card__label" style={{ margin: 0 }}>{label}</p>
      <p className="stat-card__value" style={{ fontSize: '1.6rem', marginTop: 4 }}>
        {formatValue(kpi, value, lang)}
      </p>
      <div className="politica-money__bar" style={{ marginTop: 8 }}>
        <span style={{ width: `${barPct}%` }} />
      </div>
      <p className="politica-block__text" style={{ marginTop: 8, fontSize: 11 }}>
        {best ? `✔ ${t('politica.best')}` : null}
        {best && worst ? ' · ' : null}
        {worst ? `▲ ${t('politica.worst')}` : null}
      </p>
      <div style={{ marginTop: 6 }}>
        <SourceRef ids={sourceIds} sources={sources} />
      </div>
    </div>
  );
}

function KpiCompare({ kpi, sources }) {
  const { lang, t } = useI18n();
  if (!kpi.compare || kpi.compare.length < 2) {
    return (
      <>
        <h3 className="politica-block__label">{lang === 'en' ? kpi.label_en : kpi.label_pt}</h3>
        <p className="politica-block__text">{t('politica.noCompare')}</p>
      </>
    );
  }
  const bi = bestIndex(kpi);
  const wi = kpi.compare.map((c) => c.value).indexOf(
    kpi.direction === 'higher_is_better' ? Math.min(...kpi.compare.map((c) => c.value)) : Math.max(...kpi.compare.map((c) => c.value)),
  );
  const maxAbs = Math.max(...kpi.compare.map((c) => Math.abs(c.value)), 1e-9);

  return (
    <div style={{ marginBottom: 20 }}>
      <h3 className="politica-section__title" style={{ fontSize: '1.05rem' }}>
        {lang === 'en' ? kpi.label_en : kpi.label_pt}
      </h3>
      <p className="politica-section__sub">{lang === 'en' ? kpi.plain_en : kpi.plain_pt}</p>
      <div className="stat-grid stat-grid--3">
        {kpi.compare.map((c, i) => (
          <PeriodCard
            key={c.label_pt}
            label={lang === 'en' ? c.label_en : c.label_pt}
            value={c.value}
            best={i === bi}
            worst={i === wi}
            barPct={Math.round((Math.abs(c.value) / maxAbs) * 100)}
            sourceIds={c.sources || kpi.sources}
            sources={sources}
            kpi={kpi}
            lang={lang}
          />
        ))}
      </div>
    </div>
  );
}

export default function PoliticaCompare() {
  const { t } = useI18n();
  const { data } = usePolitica();
  // Only KPIs whose compare spans government periods are worth a standalone block.
  // The two vote-share KPIs (geo_br_1t_*) are excluded here: they are a party-vs-
  // party contest, not a government-performance comparison, and the PL changed
  // candidate between 2022 and 2026 — presenting them as "best/worst period" for a
  // *party* invites a wrong reading. They still render in the geography section,
  // which carries the comparability caveat. They stay in the claims crosswalk.
  const EXCLUDED_FROM_COMPARE = new Set(['geo_br_1t_pt', 'geo_br_1t_pl']);
  const comparable = data.kpis.filter(
    (k) => (k.compare || []).length >= 2 && !EXCLUDED_FROM_COMPARE.has(k.id),
  );
  return (
    <>
      <h2 className="politica-section__title">{t('politica.navCompare')}</h2>
      <p className="politica-section__sub">{t('politica.sectionCompare')}</p>
      {comparable.map((kpi) => (
        <KpiCompare key={kpi.id} kpi={kpi} sources={data.sources} />
      ))}
    </>
  );
}
