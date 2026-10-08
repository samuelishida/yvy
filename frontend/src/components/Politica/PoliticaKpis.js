// /politica — hero numbers. Plan: politica-transparencia, Inc 4.
//
// One tile per KPI: a big number, the plain-language sentence ("what this means"),
// and a source link. The plain sentence is not decoration — it is the whole
// point for a reader with limited political literacy.

import React from 'react';
import { useI18n } from '../../i18n';
import { usePolitica } from './Politica';
import { SourceRef, formatMoney } from './politicaUi';
import { formatInt, formatPct, formatKm2 } from '../../utils/format';

function formatValue(kpi, lang) {
  const v = kpi.value;
  if (kpi.unit === '%') return formatPct(v, lang);
  if (kpi.unit === 'km²') return formatKm2(Math.round(v), lang);
  if (kpi.unit === 'R$') return `${lang === 'en' ? 'BRL ' : 'R$ '}${formatInt(Math.round(v), lang)}`;
  if (kpi.unit === 'R$ milhões') return formatMoney(v * 1e6, lang);
  if (kpi.unit === 'índice') return Number(v).toLocaleString(lang === 'en' ? 'en-US' : 'pt-BR', { minimumFractionDigits: 3, maximumFractionDigits: 3 });
  return formatInt(v, lang);
}

function KpiTile({ kpi, sources }) {
  const { lang, t } = useI18n();
  const label = lang === 'en' ? kpi.label_en : kpi.label_pt;
  const plain = lang === 'en' ? kpi.plain_en : kpi.plain_pt;
  const min = kpi.notes?.min;
  const max = kpi.notes?.max;

  return (
    <article className="stat-card" style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
      <p className="stat-card__label" style={{ margin: 0 }}>{label}</p>
      <p className="politica-big">{formatValue(kpi, lang)}</p>
      <div className="politica-plain">
        <span className="politica-plain__label">{t('politica.whatItMeans')}</span>
        {plain}
      </div>
      {min && max ? (
        <p className="politica-block__text" style={{ marginTop: 8 }}>
          {lang === 'en' ? 'Lowest' : 'Mínimo'}: {formatPct(min.value, lang)} ({min.period}) ·{' '}
          {lang === 'en' ? 'Highest' : 'Pico'}: {formatPct(max.value, lang)} ({max.period})
        </p>
      ) : null}
      <div style={{ marginTop: 10 }}>
        <SourceRef ids={kpi.sources} sources={sources} />
      </div>
    </article>
  );
}

export default function PoliticaKpis() {
  const { t } = useI18n();
  const { data } = usePolitica();
  return (
    <>
      <h2 className="politica-section__title">{t('politica.navKpis')}</h2>
      <p className="politica-section__sub">{t('politica.whatItMeans')}</p>
      <div className="stat-grid">
        {data.kpis.map((kpi) => (
          <KpiTile key={kpi.id} kpi={kpi} sources={data.sources} />
        ))}
      </div>
    </>
  );
}
