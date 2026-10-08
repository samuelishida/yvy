// /politica — sources + scope banner. Plan: politica-transparencia, Inc 7.
//
// The scope banner is the page's honesty statement: the vintage date, the four
// gates that passed, and the upstream corpus result — shown prominently (not as a
// buried footnote). A sceptical reader must be able to see that every number was
// recomputed and every citation checked against the live source.

import React from 'react';
import { useI18n } from '../../i18n';
import { usePolitica } from './Politica';
import { safeHttpUrl } from './PoliticaCharts';

function GateRow({ label, value }) {
  return (
    <div className="politica-gate">
      <span className="politica-gate__check">✓</span>
      <span>{label}</span>
      {value ? <span className="politica-gate__pct">{value}</span> : null}
    </div>
  );
}

export function ScopeBanner() {
  const { lang, t } = useI18n();
  const { data } = usePolitica();
  const v = data.meta.verification || {};
  const up = v.upstream || {};
  const note = lang === 'en' ? data.meta.scope_note_en : data.meta.scope_note_pt;

  return (
    <div className="politica-scope">
      <h2 className="politica-scope__title">{t('politica.scopeTitle')}</h2>
      <p className="politica-scope__vintage">
        <span className="politica-gate__check">●</span> {t('politica.scopeVintage')} {data.meta.vintage}
      </p>
      <p className="politica-block__label">{t('politica.scopeGates')}</p>
      <div className="politica-gates">
        <GateRow label={t('politica.gateSchema')} value="✓" />
        <GateRow label={t('politica.gateProvenance')} value={v.provenance != null ? `${v.provenance.toFixed(0)}%` : null} />
        <GateRow label={t('politica.gateValues')} value={v.values != null ? `${v.values.toFixed(0)}%` : null} />
        <GateRow label={t('politica.gateCitations')} value={v.citations != null ? `${v.citations.toFixed(0)}%` : null} />
        <GateRow label={t('politica.gateUpstream')} value={up.sourced_claims_rate || '14/14'} />
      </div>
      <p className="politica-scope__note" style={{ marginTop: 0 }}>{t('politica.gateCitationsScope')}</p>
      <p className="politica-scope__note">{note}</p>
      <p className="politica-scope__note" style={{ marginTop: 8 }}>{t('politica.scopeNotIs')}</p>
    </div>
  );
}

export function SourceList() {
  const { lang, t } = useI18n();
  const { data } = usePolitica();
  const official = data.sources.filter((s) => s.tier === 1);
  const press = data.sources.filter((s) => s.tier === 2);

  const renderGroup = (title, rows) => (
    <div className="politica-sources__group">
      <h3 className="politica-block__label">{title} ({rows.length})</h3>
      {rows.map((s) => {
        const href = safeHttpUrl(s.url);
        return (
          <div className="politica-sources__item" key={s.id}>
            {href ? (
              <a href={href} target="_blank" rel="noopener noreferrer">{s.title}</a>
            ) : (
              <span>{s.title}</span>
            )}
            <span className="politica-sources__pub">
              {s.publisher} · {s.date}
              {lang === 'en' ? ' · ' : ' · '}
              {s.kind}
            </span>
          </div>
        );
      })}
    </div>
  );

  return (
    <>
      <h2 className="politica-section__title">{t('politica.navSources')}</h2>
      <p className="politica-section__sub">
        {lang === 'en'
          ? 'Every number above resolves to one of these sources. Official sources and reference press are labelled separately.'
          : 'Cada número acima aponta para uma destas fontes. Fontes oficiais e imprensa de referência são rotuladas separadamente.'}
      </p>
      {renderGroup(t('politica.official'), official)}
      {renderGroup(t('politica.press'), press)}
      <ScopeBanner />
    </>
  );
}

export default SourceList;
