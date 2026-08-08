import React, { createContext, useContext, useEffect, useMemo, useCallback } from 'react';
import { useSearchParams } from 'react-router-dom';
import { useI18n } from '../../i18n';

// Global dashboard filter (plan: dashboard-enhancement, Inc 1).
// URL is the source of truth (?days=30&state=PA) so claims are shareable and
// survive reload; localStorage would silently reframe every number on next
// visit, React state alone is not shareable.

export const UF_LIST = [
  'AC', 'AL', 'AP', 'AM', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MT', 'MS', 'MG',
  'PA', 'PB', 'PR', 'PE', 'PI', 'RJ', 'RN', 'RS', 'RO', 'RR', 'SC', 'SP', 'SE', 'TO',
];

export const DAY_OPTIONS = [7, 30, 90];
const DEFAULT_DAYS = 30;

const FilterContext = createContext({
  days: DEFAULT_DAYS,
  state: '',
  setDays: () => {},
  setState: () => {},
  clear: () => {},
  queryString: 'days=30',
});

export function DashboardFilterProvider({ children }) {
  const [params, setParams] = useSearchParams();

  const daysRaw = params.get('days');
  const days = DAY_OPTIONS.includes(Number(daysRaw)) ? Number(daysRaw) : DEFAULT_DAYS;
  const stateRaw = String(params.get('state') || '').toUpperCase();
  const state = UF_LIST.includes(stateRaw) ? stateRaw : '';

  // Normalize invalid query values back into the URL (query string is
  // user-editable and feeds API URLs — never trust it). Only rewrites when a
  // value is present AND invalid; a clean ?days=30 or bare URL stays as-is.
  useEffect(() => {
    const next = new URLSearchParams(params);
    let changed = false;
    if (daysRaw !== null && String(days) !== daysRaw) {
      next.set('days', String(days));
      changed = true;
    }
    if (stateRaw !== '' && state !== stateRaw) {
      if (state) next.set('state', state);
      else next.delete('state');
      changed = true;
    }
    if (changed) setParams(next, { replace: true });
  }, [days, daysRaw, state, stateRaw, params, setParams]);

  const setDays = useCallback((d) => {
    const next = new URLSearchParams(params);
    if (DAY_OPTIONS.includes(d)) next.set('days', String(d));
    else next.delete('days');
    setParams(next);
  }, [params, setParams]);

  const setState = useCallback((uf) => {
    const next = new URLSearchParams(params);
    if (uf && UF_LIST.includes(uf)) next.set('state', uf);
    else next.delete('state');
    setParams(next);
  }, [params, setParams]);

  const clear = useCallback(() => {
    const next = new URLSearchParams(params);
    next.delete('days');
    next.delete('state');
    setParams(next);
  }, [params, setParams]);

  const queryString = useMemo(() => {
    const p = [`days=${days}`];
    if (state) p.push(`state=${state}`);
    return p.join('&');
  }, [days, state]);

  const value = useMemo(
    () => ({ days, state, setDays, setState, clear, queryString }),
    [days, state, setDays, setState, clear, queryString],
  );

  return <FilterContext.Provider value={value}>{children}</FilterContext.Provider>;
}

export function useDashboardFilters() {
  return useContext(FilterContext);
}

// Range segmented control + UF selector. Renders a human-readable scope
// summary that is announced on change (aria-live).
export default function FilterBar() {
  const { t } = useI18n();
  const { days, state, setDays, setState, clear } = useDashboardFilters();

  return (
    <div className="dash-filters" role="group" aria-label={t('dashboard.filterRange')}>
      <div className="dash-filters__seg">
        {DAY_OPTIONS.map((d) => (
          <button
            key={d}
            type="button"
            className={`dash-filters__btn${days === d ? ' is-active' : ''}`}
            onClick={() => setDays(d)}
            aria-pressed={days === d}
          >
            {t(`dashboard.range${d}d`)}
          </button>
        ))}
      </div>

      <label className="dash-filters__select">
        <span className="dash-filters__label">{t('dashboard.filterByState')}</span>
        <select
          value={state}
          onChange={(e) => setState(e.target.value)}
          aria-label={t('dashboard.filterByState')}
        >
          <option value="">{t('dashboard.allBrazil')}</option>
          {UF_LIST.map((uf) => (
            <option key={uf} value={uf}>{uf}</option>
          ))}
        </select>
      </label>

      <div className="dash-filters__scope" aria-live="polite">
        {t('dashboard.range' + days + 'd')}
        {state ? ` · ${state}` : ` · ${t('dashboard.allBrazil')}`}
      </div>

      {(days !== 30 || state !== '') && (
        <button type="button" className="dash-filters__clear" onClick={clear}>
          {t('dashboard.clearFilters')}
        </button>
      )}
    </div>
  );
}
