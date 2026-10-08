// /politica — electoral geography. Plan: politica-transparencia, Inc 6.
//
// Two facts: the UF-level swing, and the municipalities that moved most. Two
// correctness rules from the plan:
//   - the comparability caveat (PL changed candidate 2022→2026, PT did not) must
//     appear ABOVE the numbers, never as a footnote;
//   - municipality counts are not weighted by electorate, and we say so.

import React from 'react';
import { useI18n } from '../../i18n';
import { usePolitica } from './Politica';
import { SourceRef } from './politicaUi';
import { formatInt, formatPct, formatDeltaPct } from '../../utils/format';

function deltaClass(v) {
  return v > 0 ? 'politica-delta--up' : v < 0 ? 'politica-delta--down' : '';
}

function UfBars({ rows, sourceIds, catalog }) {
  const { lang } = useI18n();
  const maxAbs = Math.max(...rows.map((r) => Math.abs(r.pt_delta_pp)), 1);
  return (
    <>
      {rows.map((r) => (
        <div className="bar-row" key={r.uf} style={{ marginBottom: 6 }}>
          <span className="bar-swatch" style={{ background: r.uf === 'GO' ? '#FF6200' : '#8A9E93' }} />
          <span className="bar-label">
            {r.uf}{r.uf === 'GO' ? (lang === 'en' ? ' (biggest drop)' : ' (maior queda)') : ''}
          </span>
          <span className="bar-track">
            <span
              className="bar-fill"
              style={{ width: `${Math.round((Math.abs(r.pt_delta_pp) / maxAbs) * 100)}%`, background: '#F08A85' }}
            />
          </span>
          <span className="bar-count politica-delta--down">{formatDeltaPct(r.pt_delta_pp, lang)}</span>
        </div>
      ))}
      <div style={{ marginTop: 8 }}>
        <SourceRef ids={sourceIds} sources={catalog} />
      </div>
    </>
  );
}

function MunicipalityTable({ rows }) {
  const { lang, t } = useI18n();
  return (
    <table className="politica-geo__table">
      <thead>
        <tr>
          <th>{lang === 'en' ? 'Municipality' : 'Município'}</th>
          <th>UF</th>
          <th>{t('politica.votes')}</th>
          <th>{lang === 'en' ? 'Change' : 'Variação'}</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((m) => (
          <tr key={`${m.uf}-${m.name}`}>
            <td>{m.name}</td>
            <td>{m.uf}</td>
            <td>{formatInt(m.votes, lang)}</td>
            <td className={deltaClass(m.delta_pp)}>
              {m.side.toUpperCase()} {formatDeltaPct(m.delta_pp, lang)}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export default function PoliticaGeo() {
  const { lang, t } = useI18n();
  const { data } = usePolitica();
  const { geo, sources } = data;
  const sourceIds = geo.summary.sources;
  const plMun = geo.municipalities.filter((m) => m.side === 'pl');
  const ptMun = geo.municipalities.filter((m) => m.side === 'pt');

  return (
    <>
      <h2 className="politica-section__title">{t('politica.geoTitle')}</h2>
      <div className="politica-callout politica-callout--warn" role="note">
        <span className="politica-callout__icon">⚠</span>
        <span>{t('politica.geoCaveat')}</span>
      </div>
      <p className="politica-section__sub">{t('politica.geoNoWeight')}</p>

      <div className="stat-grid" style={{ marginBottom: 20 }}>
        <article className="stat-card" style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
          <p className="stat-card__label" style={{ margin: 0 }}>
            {lang === 'en' ? 'PT vote 2022 → 2026' : 'Voto PT 2022 → 2026'}
          </p>
          <p className="politica-big" style={{ fontSize: '1.8rem' }}>
            {formatPct(geo.summary.pt_2022, lang)} → {formatPct(geo.summary.pt_2026, lang)}
          </p>
          <p className="stat-card__delta politica-card__period">
            {lang === 'en' ? 'PL' : 'PL'}: {formatPct(geo.summary.pl_2022, lang)} → {formatPct(geo.summary.pl_2026, lang)}
          </p>
        </article>
        <article className="stat-card" style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
          <p className="stat-card__label" style={{ margin: 0 }}>{t('politica.majority')}</p>
          <p className="politica-big" style={{ fontSize: '1.8rem' }}>
            {formatInt(geo.summary.pl_majority_2026, lang)}
          </p>
          <p className="politica-block__text">
            {lang === 'en'
              ? `PL-led municipalities (${formatInt(geo.summary.pl_majority_2022, lang)} in 2022) · PT: ${formatInt(geo.summary.pt_majority_2022, lang)} → ${formatInt(geo.summary.pt_majority_2026, lang)}`
              : `Municípios com maioria PL (${formatInt(geo.summary.pl_majority_2022, lang)} em 2022) · PT: ${formatInt(geo.summary.pt_majority_2022, lang)} → ${formatInt(geo.summary.pt_majority_2026, lang)}`}
          </p>
        </article>
        <article className="stat-card" style={{ flexDirection: 'column', alignItems: 'flex-start' }}>
          <p className="stat-card__label" style={{ margin: 0 }}>{lang === 'en' ? 'Neither >50%' : 'Nenhum >50%'}</p>
          <p className="politica-big" style={{ fontSize: '1.8rem' }}>
            {formatInt(geo.summary.neither_2026, lang)}
          </p>
          <p className="politica-block__text">
            {lang === 'en' ? 'municipalities in 2026 (no majority of either party)' : 'municípios em 2026 (sem maioria de nenhum partido)'}
          </p>
        </article>
      </div>

      <h3 className="politica-block__label">{t('politica.ufLosers')}</h3>
      <UfBars rows={geo.uf_losers} sourceIds={sourceIds} catalog={sources} />

      <h3 className="politica-block__label" style={{ marginTop: 24 }}>{t('politica.municipalities')} — PL</h3>
      <MunicipalityTable rows={plMun} />
      <h3 className="politica-block__label" style={{ marginTop: 16 }}>{t('politica.municipalities')} — PT</h3>
      <MunicipalityTable rows={ptMun} />

      <div style={{ marginTop: 12 }}>
        <SourceRef ids={sourceIds} sources={sources} />
      </div>
    </>
  );
}
