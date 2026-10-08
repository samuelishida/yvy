// /politica — time series. Plan: politica-transparencia, Inc 4.
//
// One chart per manifest series. Every chart carries its own source line, and a
// series that ends mid-period (DETER 2026) shows a visible "partial" marker plus a
// note, so a short 9-month bar is never read as a real drop.

import React from 'react';
import { useI18n } from '../../i18n';
import { usePolitica } from './Politica';
import { SeriesChart, PERIOD_FILL, PERIOD_LABEL_FILL } from './PoliticaCharts';
import { SourceRef } from './politicaUi';

const ACCENT = {
  prodes: '#FF6200', // deforestation is fire-coloured data (DESIGN.md ember gradient)
  deter: '#FFAD00',
  desoc: '#00C97A',
  ipca12m: '#2dd4ff',
  gini: '#a78bfa',
};

export default function PoliticaSeries() {
  const { lang, t } = useI18n();
  const { data } = usePolitica();
  return (
    <>
      <h2 className="politica-section__title">{t('politica.navSeries')}</h2>
      <p className="politica-section__sub">{t('politica.seriesIntro')}</p>
      {data.series.map((s) => (
        <div key={s.id} style={{ marginBottom: 28 }}>
          <h3 className="politica-block__label" style={{ fontSize: 12 }}>
            {lang === 'en' ? s.label_en : s.label_pt}
          </h3>
          <SeriesChart series={s} accent={ACCENT[s.id] || '#00C97A'} />
          {s.periods?.length ? (
            <div className="politica-legend" aria-hidden="true">
              {s.periods.map((p) => (
                <span key={p.id} className="politica-legend__item">
                  <span
                    className="politica-legend__swatch"
                    style={{ background: PERIOD_FILL[p.tone] || PERIOD_FILL.neutral, borderColor: PERIOD_LABEL_FILL[p.tone] || PERIOD_LABEL_FILL.neutral }}
                  />
                  {lang === 'en' ? p.label_en : p.label_pt}
                </span>
              ))}
            </div>
          ) : null}
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'center', marginTop: 6 }}>
            <SourceRef ids={s.sources} sources={data.sources} />
            {s.partial_end ? (
              <span className="politica-state politica-state--alegado_na_denuncia">
                ⚠ {t('politica.partialNote')}
              </span>
            ) : null}
          </div>
        </div>
      ))}
    </>
  );
}
