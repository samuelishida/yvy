import React, { useEffect, useState, useMemo } from 'react';
import {
  ResponsiveContainer, BarChart, Bar, XAxis, YAxis, Tooltip, Cell,
  PieChart, Pie,
} from 'recharts';
import { useI18n } from '../../i18n';
import { cachedFetch } from '../../utils/apiCache';

const STATE_COLOR = '#00C97A';
const PROTECTED_COLORS = { ti: '#f59e0b', uc: '#4ade80', other: 'rgba(138, 158, 147, 0.6)' };

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

function PieTooltip({ active, payload }) {
  if (!active || !payload || !payload.length) return null;
  const p = payload[0].payload;
  return (
    <div className="dash-tooltip">
      <div className="dash-tooltip__title">{p.label}</div>
      <div className="dash-tooltip__val">{p.value.toLocaleString('pt-BR')}</div>
    </div>
  );
}

export default function GeoBreakdown() {
  const { t } = useI18n();
  const [states, setStates] = useState(null);
  const [share, setShare] = useState(null);

  useEffect(() => {
    const ac = new AbortController();
    const log = err => { if (err.name !== 'AbortError') console.error(err); };
    cachedFetch('/api/fires/by-state?limit=10', { ttl: 120_000, signal: ac.signal })
      .then(d => setStates(Array.isArray(d.states) ? d.states : []))
      .catch(log);
    cachedFetch('/api/fires/protected-share', { ttl: 300_000, signal: ac.signal })
      .then(setShare)
      .catch(log);
    return () => ac.abort();
  }, []);

  const pieData = useMemo(() => {
    if (!share) return [];
    const ti = Number(share.indigenous) || 0;
    const uc = Number(share.conservation) || 0;
    const other = Number(share.other) || 0;
    return [
      { key: 'ti',    label: t('dashboard.inTI'),         value: ti,    color: PROTECTED_COLORS.ti },
      { key: 'uc',    label: t('dashboard.inUC'),         value: uc,    color: PROTECTED_COLORS.uc },
      { key: 'other', label: t('dashboard.unprotected'),  value: other, color: PROTECTED_COLORS.other },
    ].filter(d => d.value > 0);
  }, [share, t]);

  return (
    <>
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

      <div className="chart-card">
        <div className="chart-card__header">
          <h2>{t('dashboard.protectedShare')}</h2>
        </div>
        {!share ? (
          <div className="dash-loading">{t('dashboard.loadingShort')}</div>
        ) : pieData.length === 0 ? (
          <div className="dash-loading">{t('dashboard.noData')}</div>
        ) : (
          <div className="protected-share">
            <div className="chart-canvas">
              <ResponsiveContainer width="100%" height={200}>
                <PieChart>
                  <Pie
                    data={pieData}
                    dataKey="value"
                    nameKey="label"
                    innerRadius={56}
                    outerRadius={80}
                    paddingAngle={2}
                    stroke="#0D1310"
                    strokeWidth={2}
                  >
                    {pieData.map((d, i) => <Cell key={i} fill={d.color} />)}
                  </Pie>
                  <Tooltip content={<PieTooltip />} />
                </PieChart>
              </ResponsiveContainer>
            </div>
            <ul className="protected-share__legend">
              {pieData.map(d => (
                <li key={d.key}>
                  <span className="legend-swatch" style={{ background: d.color }} />
                  <span className="legend-label">{d.label}</span>
                  <span className="legend-value">{d.value.toLocaleString('pt-BR')}</span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>
    </>
  );
}
