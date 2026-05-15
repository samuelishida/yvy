import React, { useEffect, useState } from 'react';
import {
  ResponsiveContainer, BarChart, Bar, XAxis, YAxis, Tooltip, Cell,
} from 'recharts';
import { useI18n } from '../../i18n';
import { cachedFetch } from '../../utils/apiCache';

const STATE_COLOR = '#00C97A';

const TICK_STYLE = { fill: 'rgba(138, 158, 147, 1)', fontSize: 11, fontFamily: 'var(--font-mono)' };
const AXIS_LINE = { stroke: 'rgba(42, 53, 48, 0.8)' };

function BarTooltip({ active, payload }) {
  if (!active || !payload || !payload.length) return null;
  const p = payload[0].payload;
  return (
    <div className="dash-tooltip">
      <div className="dash-tooltip__title">{p.state}</div>
      <div className="dash-tooltip__val">{p.count.toLocaleString('pt-BR')}</div>
    </div>
  );
}

export default function GeoBreakdown() {
  const { t } = useI18n();
  const [states, setStates] = useState(null);

  useEffect(() => {
    const ac = new AbortController();
    const log = err => { if (err.name !== 'AbortError') console.error(err); };
    cachedFetch('/api/fires/by-state?limit=10', { ttl: 120_000, signal: ac.signal })
      .then(d => setStates(Array.isArray(d.states) ? d.states : []))
      .catch(log);
    return () => ac.abort();
  }, []);

  return (
    <div className="chart-card">
      <div className="chart-card__header">
        <h2>{t('dashboard.top10States')}</h2>
        <span className="chart-card__total">{t('dashboard.top10StatesSub')}</span>
      </div>
      {!states ? (
        <div className="dash-loading">{t('dashboard.loadingShort')}</div>
      ) : states.length === 0 ? (
        <div className="dash-loading">{t('dashboard.noData')}</div>
      ) : (
        <div className="chart-canvas">
          <ResponsiveContainer width="100%" height={Math.max(220, states.length * 28)}>
            <BarChart data={states} layout="vertical" margin={{ top: 4, right: 16, left: 0, bottom: 0 }}>
              <XAxis type="number" tick={TICK_STYLE} axisLine={AXIS_LINE} tickLine={false} />
              <YAxis dataKey="state" type="category" tick={TICK_STYLE} axisLine={AXIS_LINE} tickLine={false} width={36} />
              <Tooltip cursor={{ fill: 'rgba(255,255,255,0.04)' }} content={<BarTooltip />} />
              <Bar dataKey="count" radius={[0, 3, 3, 0]}>
                {states.map((_, i) => <Cell key={i} fill={STATE_COLOR} />)}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}
    </div>
  );
}
