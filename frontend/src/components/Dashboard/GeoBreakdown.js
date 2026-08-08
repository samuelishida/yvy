import React, { useMemo, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  ResponsiveContainer, BarChart, Bar, XAxis, YAxis, Tooltip, Cell,
  AreaChart, Area, CartesianGrid,
} from 'recharts';
import { useI18n } from '../../i18n';
import { useDashboardFilters } from './DashboardFilters';
import useCardData from './useCardData';
import CardShell from './CardShell';
import { mapUrlForState } from '../../utils/mapLinks';
import { formatInt } from '../../utils/format';

const TICK_STYLE = { fill: 'rgba(138,158,147,1)', fontSize: 11, fontFamily: 'var(--font-mono)' };
const AXIS_LINE = { stroke: 'rgba(42,53,48,0.8)' };

function StateTooltip({ active, payload }) {
  if (!active || !payload || !payload.length) return null;
  const p = payload[0].payload;
  return (
    <div className="dash-tooltip">
      <div className="dash-tooltip__title">{p.state}</div>
      <div className="dash-tooltip__val">{formatInt(p.count, 'en-US')}</div>
    </div>
  );
}

function DailyTooltip({ active, payload }) {
  if (!active || !payload || !payload.length) return null;
  const p = payload[0].payload;
  return (
    <div className="dash-tooltip">
      <div className="dash-tooltip__title">{p.date}</div>
      <div className="dash-tooltip__val">{formatInt(p.count, 'en-US')}</div>
    </div>
  );
}

// Top-10 states by fires in the selected window; when a single state is
// selected the ranking is meaningless, so we show that state's daily series
// instead (plan: dashboard-enhancement, Inc 7).
export default function GeoBreakdown() {
  const { t } = useI18n();
  const { lang } = useI18n();
  const { days, state } = useDashboardFilters();
  const navigate = useNavigate();
  const chartRef = useRef(null);

  const scope = state
    ? t('dashboard.scopeLabel', { window: t(`dashboard.range${days}d`), region: state })
    : t(`dashboard.range${days}d`);

  const url = state
    ? `/api/fires/timeseries?days=${days}&state=${state}`
    : `/api/fires/by-state?days=${days}&limit=10`;
  const { data, cardState, retry } = useCardData(url, {
    ttl: 120_000,
    isEmpty: state
      ? (d) => !d || !Array.isArray(d.series) || d.series.length === 0
      : (d) => !d || !Array.isArray(d.states) || d.states.length === 0,
  });

  const states = useMemo(() => (data ? (data.states || []).map((s) => ({ ...s, state: s.state })) : []), [data]);
  const series = useMemo(() => (data ? (data.series || []) : []), [data]);

  const title = state ? t('dashboard.dailyFiresState') : t('dashboard.top10States');

  return (
    <CardShell
      title={title}
      state={cardState}
      onRetry={retry}
      freshness={{ windowLabel: scope }}
      chartRef={chartRef}
      exportData={state
        ? { filename: `yvy-daily-${state}-${days}d.csv`, rows: series.map((s) => ({ date: s.date, fires: s.count })) }
        : { filename: `yvy-states-${days}d.csv`, rows: states.map((s) => ({ state: s.state, fires: s.count })) }}
    >
      <div className="chart-canvas" ref={chartRef}>
        {state ? (
          <ResponsiveContainer width="100%" height={260}>
            <AreaChart data={series} margin={{ top: 8, right: 16, left: 0, bottom: 0 }}>
              <CartesianGrid stroke="rgba(42,53,48,0.4)" strokeDasharray="2 4" vertical={false} />
              <XAxis dataKey="date" tick={TICK_STYLE} axisLine={AXIS_LINE} tickLine={false}
                     tickFormatter={(d) => (typeof d === 'string' ? d.slice(5) : d)} minTickGap={24} />
              <YAxis tick={TICK_STYLE} axisLine={AXIS_LINE} tickLine={false} width={48} />
              <Tooltip cursor={{ stroke: 'rgba(255,255,255,0.2)' }} content={<DailyTooltip />} />
              <Area dataKey="count" name="fires" stroke="#00C97A" fill="rgba(0,201,122,0.18)" strokeWidth={1.5} />
            </AreaChart>
          </ResponsiveContainer>
        ) : (
          <ResponsiveContainer width="100%" height={Math.max(220, states.length * 28)}>
            <BarChart data={states} layout="vertical" margin={{ top: 4, right: 16, left: 0, bottom: 0 }}>
              <XAxis type="number" tick={TICK_STYLE} axisLine={AXIS_LINE} tickLine={false} />
              <YAxis dataKey="state" type="category" tick={TICK_STYLE} axisLine={AXIS_LINE} tickLine={false} width={36} />
              <Tooltip cursor={{ fill: 'rgba(255,255,255,0.04)' }} content={<StateTooltip />} />
              <Bar
                dataKey="count"
                radius={[0, 3, 3, 0]}
                onClick={(entry) => {
                  if (entry && entry.state) navigate(mapUrlForState(entry.state, days));
                }}
                className="dash-bar-clickable"
              >
                {states.map((s) => <Cell key={s.state} fill="#00C97A" />)}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        )}
      </div>
      {!state && <p className="chart-card__hint">{t('dashboard.clickStateMap')}</p>}
    </CardShell>
  );
}
