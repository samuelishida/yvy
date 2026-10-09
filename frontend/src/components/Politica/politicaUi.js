// /politica — shared presentational primitives. Plan: politica-transparencia, Inc 3-7.
//
// Two ideas drive everything here:
//   1. Redundancy for low-literacy readers. A legal status is NEVER colour alone —
//      it is icon + colour + one-line phrase, because the audience includes voters
//      with little political information capital, who could otherwise read an
//      annulled conviction as a current one.
//   2. Every number links to its source. `SourceRef` is the only way a number is
//      rendered, so "the source is a button, not an invisible footer" holds by
//      construction.

import React from 'react';
import { useI18n } from '../../i18n';

// ── status → icon + i18n key ─────────────────────────────────────────────────
// Icons are inline SVG so the panel needs no new dependency. Each is a distinct
// SHAPE, not just a colour, so the status survives greyscale and colour-blindness.
const STATUS_ICON = {
  condenado_anulado: (
    // broken shield: a conviction that did not stand
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <path d="M12 3l7 3v6c0 4-3 7-7 9-4-2-7-5-7-9V6l7-3z" />
      <path d="M9 12l2 2 4-4" strokeDasharray="2 2" />
    </svg>
  ),
  prescrito: (
    // clock: ran out of time
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <circle cx="12" cy="12" r="8" />
      <path d="M12 8v4l3 2" />
    </svg>
  ),
  denunciado_arquivado: (
    // closed folder: shelved without a ruling
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2V7z" />
      <path d="M3 13h18" />
    </svg>
  ),
  absolvido: (
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <circle cx="12" cy="12" r="8" />
      <path d="M8.5 12l2.5 2.5 4.5-5" />
    </svg>
  ),
  nunca_reu: (
    // struck circle: never charged
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <circle cx="12" cy="12" r="8" />
      <path d="M7 17L17 7" />
    </svg>
  ),
  em_curso: (
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <circle cx="12" cy="12" r="4" />
      <circle cx="12" cy="12" r="8" strokeDasharray="2 3" />
    </svg>
  ),
  sob_investigacao: (
    // magnifying glass: an inquiry is active, no finding is implied
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <circle cx="10.5" cy="10.5" r="6.5" />
      <path d="M15.5 15.5L21 21" />
    </svg>
  ),
  nao_confirmado: (
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <circle cx="12" cy="12" r="8" />
      <path d="M9.5 9a2.5 2.5 0 114 2c-.9.7-1.5 1.2-1.5 2.3" />
      <path d="M12 17h.01" />
    </svg>
  ),
};

const EVIDENCE_ICON = {
  anulado: (
    <svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" strokeWidth="2.2" aria-hidden="true">
      <path d="M5 5l14 14M19 5L5 19" />
    </svg>
  ),
  usado_no_processo: (
    <svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" strokeWidth="2.2" aria-hidden="true">
      <path d="M5 12l4 4 10-10" />
    </svg>
  ),
  alegado_na_denuncia: (
    <svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" strokeWidth="2.2" aria-hidden="true">
      <circle cx="12" cy="12" r="4" />
    </svg>
  ),
  alegado_em_apuracao: (
    <svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" strokeWidth="2.2" aria-hidden="true">
      <circle cx="10" cy="10" r="6" />
      <path d="M14.5 14.5L20 20" />
    </svg>
  ),
};

// `StatusPill` — icon + colour + enum label. Colour class comes from the enum, so
// an unknown status can never be styled as if it were benign.
export function StatusPill({ status }) {
  const { t } = useI18n();
  return (
    <span className={`politica-status politica-status--${status}`}>
      <span className="politica-status__icon">{STATUS_ICON[status]}</span>
      {t(`politica.status_${status}`)}
    </span>
  );
}

export function StatusPhrase({ status }) {
  const { t } = useI18n();
  return <p className="politica-card__phrase">{t(`politica.statusPhrase_${status}`)}</p>;
}

export function StatePill({ state }) {
  const { t } = useI18n();
  return (
    <span className={`politica-state politica-state--${state}`}>
      {EVIDENCE_ICON[state]}
      {t(`politica.state_${state}`)}
    </span>
  );
}

// `SourceRef` — the ONLY way a number exposes its origin. Renders the first
// source's publisher as a dotted link; extra sources append as "+n".
export function SourceRef({ ids, sources }) {
  const { t } = useI18n();
  if (!Array.isArray(ids) || ids.length === 0) return null;
  const first = sources.find((s) => s.id === ids[0]);
  if (!first) return null;
  const safe = /^https?:\/\//.test(first.url) ? first.url : null;
  return (
    <span className="politica-source">
      <span className="politica-source__publisher">{t('politica.source')}:&nbsp;</span>
      {safe ? (
        <a href={safe} target="_blank" rel="noopener noreferrer" className="politica-source">
          {first.publisher}
        </a>
      ) : (
        <span>{first.publisher}</span>
      )}
      {ids.length > 1 ? <span>{` +${ids.length - 1}`}</span> : null}
    </span>
  );
}

// `formatMoney(v, lang)` — the plan's only required formatter addition.
// pt → "R$ 6,2 bi"; en → "BRL 6.2 bi" (ISO prefix, since "R$" is meaningless to
// an English reader). Never rounds a sub-million value up into a "mi" figure that
// could be confused with a different, forbidden amount.
export function formatMoney(v, lang) {
  const n = Number(v);
  if (!Number.isFinite(n)) return '—';
  const prefix = lang === 'en' ? 'BRL ' : 'R$ ';
  const locale = lang === 'en' ? 'en-US' : 'pt-BR';
  if (n === 0) return `${prefix}0`;
  if (n >= 1e12) return `${prefix}${(n / 1e12).toLocaleString(locale, { maximumFractionDigits: 1 })} tri`;
  if (n >= 1e9) return `${prefix}${(n / 1e9).toLocaleString(locale, { maximumFractionDigits: 1 })} bi`;
  if (n >= 1e6) return `${prefix}${(n / 1e6).toLocaleString(locale, { maximumFractionDigits: 1 })} mi`;
  // Below a million: show the exact figure — never a rounded "mi" (the plan bans
  // rounding R$ 2.062.360,52 to a figure resembling "2,06 mi").
  return `${prefix}${n.toLocaleString(locale, { maximumFractionDigits: 2, minimumFractionDigits: 0 })}`;
}

// Full-precision money, for the tooltip where a rounded label could mislead.
export function formatMoneyExact(v, lang) {
  const n = Number(v);
  if (!Number.isFinite(n)) return '—';
  const prefix = lang === 'en' ? 'BRL ' : 'R$ ';
  return `${prefix}${n.toLocaleString(lang === 'en' ? 'en-US' : 'pt-BR', { maximumFractionDigits: 2 })}`;
}
