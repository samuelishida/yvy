// /politica — chart primitives. Plan: politica-transparencia, Inc 4.
//
// TICK_STYLE / AXIS_LINE / safeHttpUrl are declared ONCE here and imported by every
// chart, per the plan's decision: a "only if duplicated twice" rule is not
// verifiable, so the shared style lives in one module by construction.

import React from 'react';
import {
  ResponsiveContainer, LineChart, AreaChart, Area, Line, XAxis, YAxis, CartesianGrid, Tooltip, ReferenceLine, ReferenceDot, ReferenceArea, Label,
} from 'recharts';
import { useI18n } from '../../i18n';

export const TICK_STYLE = { fill: 'rgba(138, 158, 147, 1)', fontSize: 11, fontFamily: 'var(--font-mono)' };
// Period-band tints. Deliberately NOT the ember fire-data gradient and not --signal:
// these are neutral governance bands, alternating only to separate one term from the
// next. `a` is a warm neutral, `b` a cool neutral, `neutral` is barely-there.
export const PERIOD_FILL = {
  a: 'rgba(251, 191, 36, 0.075)',
  b: 'rgba(45, 212, 255, 0.070)',
  neutral: 'rgba(138, 158, 147, 0.06)',
};
export const PERIOD_LABEL_FILL = {
  a: 'rgba(251, 191, 36, 0.85)',
  b: 'rgba(93, 216, 255, 0.85)',
  neutral: 'rgba(138, 158, 147, 0.9)',
};
export const AXIS_LINE = { stroke: 'rgba(42, 53, 48, 0.8)' };

export function safeHttpUrl(raw) {
  try {
    const u = new URL(raw || '');
    return u.protocol === 'https:' || u.protocol === 'http:' ? u.href : null;
  } catch {
    return null;
  }
}

// Compact axis label: "2012-03" → "12/03"? No — keep it honest and short: "03/12".
function shortTick(v, unit) {
  const s = String(v);
  if (unit === 'km²' && /^\d{4}$/.test(s)) return s;
  const m = s.match(/^(\d{4})-(\d{2})$/);
  if (m) return `${m[2]}/${m[1].slice(2)}`;
  return s;
}

function ChartTooltip({ active, payload, unit, series }) {
  const { t } = useI18n();
  if (!active || !payload || !payload.length) return null;
  const p = payload[0];
  const label = p?.payload?.x ?? p?.label;
  const val = p?.value;
  return (
    <div className="dash-tooltip">
      <div className="dash-tooltip__title">{shortTick(label, series.unit)}</div>
      <div className="dash-tooltip__row">
        <span>{series[`label_${'pt'}`] ? t('politica.whatItMeans') : ''}</span>
      </div>
      <div className="dash-tooltip__value">
        {typeof val === 'number' ? val.toLocaleString('pt-BR') : '—'} {unit}
      </div>
    </div>
  );
}

// `markPartialEnd` — when a series ends mid-period (DETER 2026 has 9 months), the
// last point is flagged so the reader is not shown a "dip" that is really an
// incomplete denominator.
export function markPartialEnd(series) {
  if (!series.partial_end || series.x.length === 0) return null;
  const i = series.x.length - 1;
  return { x: series.x[i], y: series.y[i] };
}

// `SeriesChart` — one line, government-term bands, an optional partial-end dot,
// tabular axis, and the source line beneath rendered by the caller.
export function SeriesChart({ series, accent = '#00C97A' }) {
  const { lang } = useI18n();
  const data = series.x.map((x, i) => ({ x, y: series.y[i] }));
  const partial = markPartialEnd(series);
  const isArea = series.id === 'prodes'; // the flagship series gets a filled area
  const Chart = isArea ? AreaChart : LineChart;
  const periods = series.periods || [];
  // Monthly series have wide bands → full period label. Annual series have narrow
  // bands → the short label, so adjacent terms (Dilma 2 / Temer) do not collide.
  const monthly = series.x.length > 0 && /^\d{4}-\d{2}$/.test(series.x[0]);

  return (
    <ResponsiveContainer width="100%" height={260}>
      <Chart data={data} margin={{ top: 20, right: 16, bottom: 4, left: 0 }}>
        <CartesianGrid stroke="rgba(42, 53, 48, 0.5)" strokeDasharray="3 3" vertical={false} />
        {/* Government-term demarcations, drawn behind the data line so the reader
            sees which term each stretch of the curve belongs to. */}
        {periods.map((p) => (
          <ReferenceArea
            key={p.id}
            x1={p.x1}
            x2={p.x2}
            fill={PERIOD_FILL[p.tone] || PERIOD_FILL.neutral}
            stroke="none"
            ifOverflow="hidden"
          >
            <Label
              value={monthly
                ? (lang === 'en' ? p.label_en : p.label_pt)
                : (lang === 'en' ? p.short_en : p.short_pt)}
              position="insideTop"
              fill={PERIOD_LABEL_FILL[p.tone] || PERIOD_LABEL_FILL.neutral}
              fontSize={10}
              offset={6}
            />
          </ReferenceArea>
        ))}
        <XAxis
          dataKey="x"
          tick={TICK_STYLE}
          tickLine={false}
          axisLine={AXIS_LINE}
          minTickGap={28}
          tickFormatter={(v) => shortTick(v, series.unit)}
        />
        <YAxis tick={TICK_STYLE} tickLine={false} axisLine={AXIS_LINE} width={48} />
        <Tooltip content={<ChartTooltip unit={series.unit} series={series} />} />
        {partial ? (
          <ReferenceDot x={partial.x} y={partial.y} r={4} fill={accent} stroke="var(--canvas)" strokeWidth={2} />
        ) : null}
        {partial ? <ReferenceLine x={partial.x} stroke="rgba(251, 146, 60, 0.5)" strokeDasharray="3 3" /> : null}
        {isArea ? (
          <Area type="monotone" dataKey="y" stroke={accent} strokeWidth={2} fill={accent} fillOpacity={0.12} dot={false} />
        ) : (
          <Line type="monotone" dataKey="y" stroke={accent} strokeWidth={2} dot={false} activeDot={{ r: 4 }} />
        )}
      </Chart>
    </ResponsiveContainer>
  );
}
