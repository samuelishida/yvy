import React, { useEffect, useState, useMemo } from 'react';
import {
  ResponsiveContainer, LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip,
} from 'recharts';
import { useI18n } from '../../i18n';
import { cachedFetch } from '../../utils/apiCache';

const TICK_STYLE = { fill: 'rgba(138, 158, 147, 1)', fontSize: 11, fontFamily: 'var(--font-mono)' };
const AXIS_LINE = { stroke: 'rgba(42, 53, 48, 0.8)' };

function formatDate(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
}

function TooltipContent({ active, payload }) {
  if (!active || !payload || !payload.length) return null;
  const { date, count } = payload[0].payload;
  return (
    <div className="dash-tooltip">
      <div className="dash-tooltip__title">{formatDate(date)}</div>
      <div className="dash-tooltip__val">{count.toLocaleString('pt-BR')}</div>
    </div>
  );
}

export default function FireTrend({ days = 30, state = null }) {
  const { t } = useI18n();
  const [series, setSeries] = useState(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    const ac = new AbortController();
    const url = `/api/fires/timeseries?days=${days}${state ? `&state=${state}` : ''}`;
    cachedFetch(url, { ttl: 60_000, signal: ac.signal })
      .then(d => setSeries(Array.isArray(d.series) ? d.series : []))
      .catch(err => { if (err.name !== 'AbortError') setError(true); });
    return () => ac.abort();
  }, [days, state]);

  const data = useMemo(() => {
    if (!series) return [];
    return series.map(p => ({ date: p.date, count: Number(p.count) || 0 }));
  }, [series]);

  return (
    <div className="chart-card chart-card--trend">
      <div className="chart-card__header">
        <h2>{t('dashboard.fireTrend')}</h2>
        <span className="chart-card__total">{t('dashboard.fireTrendSub', { days })}</span>
      </div>
      {error ? (
        <div className="dash-loading">{t('dashboard.noData')}</div>
      ) : !series ? (
        <div className="dash-loading">{t('dashboard.loadingShort')}</div>
      ) : data.length === 0 ? (
        <div className="dash-loading">{t('dashboard.noData')}</div>
      ) : (
        <div className="chart-canvas">
          <ResponsiveContainer width="100%" height={220}>
            <LineChart data={data} margin={{ top: 8, right: 12, left: 0, bottom: 0 }}>
              <CartesianGrid stroke="rgba(42, 53, 48, 0.4)" strokeDasharray="2 4" vertical={false} />
              <XAxis
                dataKey="date"
                tickFormatter={d => formatDate(d)}
                tick={TICK_STYLE}
                axisLine={AXIS_LINE}
                tickLine={false}
                minTickGap={32}
              />
              <YAxis
                tick={TICK_STYLE}
                axisLine={AXIS_LINE}
                tickLine={false}
                width={42}
                allowDecimals={false}
              />
              <Tooltip cursor={{ stroke: 'rgba(255,98,0,0.3)' }} content={<TooltipContent />} />
              <Line
                type="monotone"
                dataKey="count"
                stroke="#FF6200"
                strokeWidth={2}
                dot={false}
                activeDot={{ r: 4, stroke: '#FF6200', strokeWidth: 2, fill: '#0D1310' }}
              />
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}
    </div>
  );
}
