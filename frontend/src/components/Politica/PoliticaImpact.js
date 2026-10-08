// /politica — financial impact. Plan: politica-transparencia, Inc 5.
//
// The single biggest misreading risk is "Lula took R$ 6.2 bn" or "Flávio took
// R$ 2 mi". The fix is structural: every bar is labelled with the OBJECT and the
// ORGANISATION that measured it, objects are grouped (never summed), and a
// prominent disclaimer states the values are not comparable. There is deliberately
// no "total" bar.

import React from 'react';
import { useI18n } from '../../i18n';
import { usePolitica } from './Politica';
import { SourceRef, formatMoney, formatMoneyExact } from './politicaUi';

function CaseMoney({ c, sources }) {
  const { lang } = useI18n();
  if (!c.financial || c.financial.length === 0) return null;
  const max = Math.max(...c.financial.map((f) => f.value));
  const name = lang === 'en' ? c.name_en : c.name_pt;
  return (
    <div style={{ marginBottom: 20 }}>
      <h3 className="politica-block__label">
        {lang === 'en' ? `${c.side.toUpperCase()} — ` : `${c.side.toUpperCase()} — `}{name}
      </h3>
      <div className="politica-money">
        {c.financial.map((f) => (
          <div key={`${c.id}-${f.value}`} className="politica-money__row">
            <span className="politica-money__value" title={formatMoneyExact(f.value, lang)}>
              {formatMoney(f.value, lang)}
            </span>
            <span className="politica-money__object">
              {lang === 'en' ? f.object_en || f.object : f.object}
            </span>
            <span className="politica-money__bar">
              <span style={{ width: `${Math.max(3, Math.round((f.value / max) * 100))}%` }} />
            </span>
            <span className="politica-money__meta">
              {lang === 'en' ? 'Measured by' : 'Medido por'}: {f.measuredBy} ·{' '}
              {lang === 'en' ? 'nature' : 'natureza'}: {lang === 'en' ? f.status : f.status} ·{' '}
              <SourceRef ids={f.sources} sources={sources} />
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

export default function PoliticaImpact() {
  const { t } = useI18n();
  const { data } = usePolitica();
  const withMoney = data.cases.filter((c) => c.financial && c.financial.length > 0);

  return (
    <>
      <h2 className="politica-section__title">{t('politica.navImpact')}</h2>
      <div className="politica-callout politica-callout--warn" role="note">
        <span className="politica-callout__icon">⚠</span>
        <span>{t('politica.moneyNotComparable')}</span>
      </div>
      <p className="politica-section__sub">{t('politica.moneyScope')}</p>
      {withMoney.map((c) => (
        <CaseMoney key={c.id} c={c} sources={data.sources} />
      ))}
    </>
  );
}
