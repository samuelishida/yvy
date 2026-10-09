// /politica — legal dossiê. Plan: politica-transparencia, Inc 5.
//
// The comparison of Lula's and Flávio's cases, side by side. The design is
// deliberately redundant: every case shows a status pill (icon + colour + phrase)
// that the reader can understand at a glance, and the phrase is repeated in plain
// words. A "convicted" reading of an annulled case is the single worst failure
// mode, so the status is never just text or just colour.

import React from 'react';
import { useI18n } from '../../i18n';
import { usePolitica } from './Politica';
import { StatusPill, StatusPhrase, StatePill, SourceRef, formatMoney, formatMoneyExact } from './politicaUi';

function MoneyRow({ f, sources, lang, max }) {
  const { t } = useI18n();
  const label = lang === 'en' ? f.object_en || f.object : f.object;
  const pct = Math.max(2, Math.round((f.value / max) * 100));
  return (
    <div className="politica-money__row">
      <span className="politica-money__value" title={formatMoneyExact(f.value, lang)}>
        {formatMoney(f.value, lang)}
      </span>
      <span className="politica-money__object">{label}</span>
      <span className="politica-money__bar"><span style={{ width: `${pct}%` }} /></span>
      <span className="politica-money__meta">
        {t('politica.measuredBy')}: {f.measuredBy} · {t('politica.nature')}: {t(`politica.nature_${f.status}`)} ·{' '}
        <SourceRef ids={f.sources} sources={sources} />
      </span>
    </div>
  );
}

function CaseCard({ c, sources }) {
  const { lang, t } = useI18n();
  const name = lang === 'en' ? c.name_en : c.name_pt;
  const allegation = lang === 'en' ? c.allegation_en : c.allegation_pt;
  const note = lang === 'en' ? c.status_note_en : c.status_note_pt;
  const defense = lang === 'en' ? c.defense_en : c.defense_pt;
  const citation = lang === 'en' ? c.status_citation_en : c.status_citation_pt;
  const citationScope = lang === 'en' ? c.citation_scope_en : c.citation_scope_pt;
  const max = c.financial.length ? Math.max(...c.financial.map((f) => f.value)) : 1;

  return (
    <article className={`politica-card politica-card--side-${c.side}`} data-case-id={c.id}>
      <div className="politica-card__head">
        <h3 className="politica-card__name">{name}</h3>
        <span className="politica-card__period">{c.period}</span>
      </div>

      <StatusPill status={c.status} />
      <div style={{ marginTop: 10 }}>
        <StatusPhrase status={c.status} />
      </div>
      <p className="politica-block__text">{note}</p>

      {c.status === 'nao_confirmado' ? (
        <div className="politica-callout politica-callout--warn" style={{ marginTop: 12 }}>
          <span className="politica-callout__icon">⚠</span>
          <span>{t('politica.notUsable')}</span>
        </div>
      ) : null}

      <div className="politica-block">
        <p className="politica-block__label">{t('politica.allegation')}</p>
        <p className="politica-block__text">{allegation}</p>
      </div>

      {c.financial.length > 0 ? (
        <div className="politica-block">
          <p className="politica-block__label">{t('politica.financial')}</p>
          <div className="politica-money">
            {c.financial.map((f) => (
              <MoneyRow key={`${f.measuredBy}-${f.value}`} f={f} sources={sources} lang={lang} max={max} />
            ))}
          </div>
        </div>
      ) : null}

      <div className="politica-block">
        <p className="politica-block__label">{t('politica.evidence')}</p>
        {c.evidence.map((e) => (
          <div key={e.claim_id || e.artifact_pt} style={{ marginBottom: 8 }}>
            <p className="politica-block__text" style={{ color: 'var(--ink)' }}>
              {lang === 'en' ? e.artifact_en || e.artifact_pt : e.artifact_pt}
            </p>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, alignItems: 'center', marginTop: 4 }}>
              <StatePill state={e.state} />
              <SourceRef ids={e.sources} sources={sources} />
            </div>
          </div>
        ))}
      </div>

      <details className="politica-disclosure">
        <summary>{t('politica.understandMinute')}</summary>
        <div className="politica-block" style={{ borderTop: 'none', marginTop: 0 }}>
          <p className="politica-block__label">{t('politica.citation')}</p>
          {citation ? <blockquote className="politica-quote">{citation}</blockquote> : null}
          <div className="politica-status-sources">
            {Array.isArray(c.status_sources) && c.status_sources.length > 0
              ? c.status_sources.map((id) => (
                <span key={id} data-source-id={id}>
                  <SourceRef ids={[id]} sources={sources} />
                </span>
              ))
              : <SourceRef ids={c.sources} sources={sources} />}
          </div>
          {citationScope ? (
            <p className="politica-block__text" style={{ fontSize: 12, fontStyle: 'italic' }}>{citationScope}</p>
          ) : null}
          <p className="politica-block__label" style={{ marginTop: 10 }}>{t('politica.defense')}</p>
          <p className="politica-block__text">{defense}</p>
        </div>
      </details>
    </article>
  );
}

// All citations rendered once, so a sceptical reader can read every verbatim quote
// the panel relies on without opening each case.
function CitationsBlock({ cases, sources }) {
  const { lang, t } = useI18n();
  const rows = cases.flatMap((c) => (c.citations || []).map((q) => ({ ...q, caseName: lang === 'en' ? c.name_en : c.name_pt })));
  return (
    <details className="politica-disclosure" style={{ marginTop: 16 }}>
      <summary>{t('politica.citation')} ({rows.length})</summary>
      {rows.map((q) => (
        <div key={q.claim_id} style={{ marginBottom: 10 }}>
          <p className="politica-block__label" style={{ marginBottom: 2 }}>{q.caseName}</p>
          <blockquote className="politica-quote">{q.text_pt}</blockquote>
          <SourceRef ids={q.sources} sources={sources} />
        </div>
      ))}
    </details>
  );
}

export default function PoliticaDossier() {
  const { t } = useI18n();
  const { data } = usePolitica();
  const lula = data.cases.filter((c) => c.side === 'pt');
  const flavio = data.cases.filter((c) => c.side === 'pl');

  return (
    <>
      <h2 className="politica-section__title">{t('politica.dossierTitle')}</h2>
      <p className="politica-section__sub">{t('politica.dossierIntro')}</p>

      <h3 className="politica-block__label">PT — Lula</h3>
      <div className="politica-cards">
        {lula.map((c) => <CaseCard key={c.id} c={c} sources={data.sources} />)}
      </div>

      <h3 className="politica-block__label" style={{ marginTop: 24 }}>PL — Flávio Bolsonaro</h3>
      <div className="politica-cards">
        {flavio.map((c) => <CaseCard key={c.id} c={c} sources={data.sources} />)}
      </div>

      <CitationsBlock cases={data.cases} sources={data.sources} />
    </>
  );
}
