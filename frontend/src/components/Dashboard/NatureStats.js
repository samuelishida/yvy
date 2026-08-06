import React, { useEffect, useState, useMemo } from 'react';
import { useI18n } from '../../i18n';
import { cachedFetch } from '../../utils/apiCache';

// Ordem de exibição das classes; cores espelham FIRE_NATURE_COLORS do mapa.
const CLASS_ORDER = ['crime', 'suspeito', 'permitido', 'natural', 'unclassified'];

const CLASS_COLORS = {
  crime:        '#ef4444',
  suspeito:     '#f97316',
  permitido:    '#22c55e',
  natural:      '#38bdf8',
  unclassified: '#9ca3af',
};

export default function NatureStats() {
  const { t } = useI18n();
  const [data, setData] = useState(null);

  useEffect(() => {
    const ac = new AbortController();
    const log = err => { if (err.name !== 'AbortError') console.error('NatureStats fetch error:', err); };
    cachedFetch('/api/fires/nature-stats?days=7', { ttl: 120_000, signal: ac.signal })
      .then(d => setData(d))
      .catch(log);
    return () => ac.abort();
  }, []);

  const classes = useMemo(() => {
    if (!data || !data.classes) return null;
    return CLASS_ORDER
      .map(key => ({ key, count: data.classes[key] || 0 }))
      .filter(c => c.count > 0);
  }, [data]);

  const classMax = useMemo(() => Math.max(...(classes || []).map(c => c.count), 1), [classes]);

  const byState = useMemo(() => {
    if (!data || !Array.isArray(data.by_state)) return null;
    return data.by_state.slice(0, 10);
  }, [data]);

  return (
    <div className="chart-card">
      <div className="chart-card__header">
        <h2>{t('dashboard.natureStats')}</h2>
        <span className="chart-card__total">
          {data ? `${(data.total || 0).toLocaleString('pt-BR')} · ${t('dashboard.natureStatsSub')}` : t('dashboard.loadingShort')}
        </span>
      </div>
      {!data ? (
        <div className="dash-loading">{t('dashboard.loadingShort')}</div>
      ) : (
        <>
          <div className="nature-classes">
            {(!classes || classes.length === 0) ? (
              <div className="dash-loading">{t('dashboard.noData')}</div>
            ) : (
              classes.map(c => {
                const pct = Math.max(2, (c.count / classMax) * 100);
                return (
                  <div key={c.key} className="bar-row">
                    <div className="bar-swatch" style={{ background: CLASS_COLORS[c.key] }} />
                    <div className="bar-label">{t(`home.nature_${c.key}`)}</div>
                    <div className="bar-track">
                      <div className="bar-fill" style={{ width: `${pct}%`, background: CLASS_COLORS[c.key] }} />
                    </div>
                    <div className="bar-nums">
                      <span className="bar-count">{c.count.toLocaleString('pt-BR')}</span>
                    </div>
                  </div>
                );
              })
            )}
          </div>
          {byState && byState.length > 0 && (
            <div className="nature-by-state">
              <div className="nature-by-state__title">{t('dashboard.natureByState')}</div>
              {byState.map(st => {
                const shares = CLASS_ORDER
                  .filter(k => (st[k] || 0) > 0)
                  .map(k => ({ key: k, count: st[k] || 0 }));
                return (
                  <div key={st.state} className="nature-state-row">
                    <div className="nature-state-label">{st.state || '—'}</div>
                    <div className="nature-state-track">
                      {shares.map(s => (
                        <div
                          key={s.key}
                          className="nature-state-seg"
                          style={{ width: `${(s.count / st.total) * 100}%`, background: CLASS_COLORS[s.key] }}
                          title={`${t(`home.nature_${s.key}`)}: ${s.count.toLocaleString('pt-BR')}`}
                        />
                      ))}
                    </div>
                    <div className="nature-state-total">{st.total.toLocaleString('pt-BR')}</div>
                  </div>
                );
              })}
            </div>
          )}
        </>
      )}
    </div>
  );
}
