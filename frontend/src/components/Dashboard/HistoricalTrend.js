import React, { useEffect, useState, useMemo } from 'react';
import {
  ResponsiveContainer, ComposedChart, Bar, Line, XAxis, YAxis, CartesianGrid, Tooltip, Cell,
} from 'recharts';
import { useI18n } from '../../i18n';
import { cachedFetch } from '../../utils/apiCache';

const TICK_STYLE = { fill: 'rgba(138, 158, 147, 1)', fontSize: 11, fontFamily: 'var(--font-mono)' };
const AXIS_LINE = { stroke: 'rgba(42, 53, 48, 0.8)' };

function colorForDelta(delta) {
  if (delta == null) return '#00C97A';
  if (delta > 0.05) return '#EF5350';
  if (delta < -0.05) return '#4ade80';
  return '#FBBF24';
}

function buildData(yearly) {
  const sorted = [...yearly].sort((a, b) => a.year - b.year);
  return sorted.map((row, i) => {
    const prev = i > 0 ? sorted[i - 1].amazon_km2 : null;
    const delta = prev ? (row.amazon_km2 - prev) / prev : null;
    const movingAvg = i >= 4
      ? sorted.slice(i - 4, i + 1).reduce((s, r) => s + r.amazon_km2, 0) / 5
      : null;
    return {
      year: row.year,
      km2: row.amazon_km2,
      delta,
      movingAvg,
    };
  });
}

function safeHttpUrl(raw) {
  try {
    const u = new URL(raw || '');
    return (u.protocol === 'https:' || u.protocol === 'http:') ? u.href : '#';
  } catch {
    return '#';
  }
}

const SAO_PAULO_KM2 = 1521;
const FIELD_KM2 = 0.00714;

function equivalence(km2) {
  if (!Number.isFinite(km2) || km2 <= 0) return null;
  const sp = Math.round(km2 / SAO_PAULO_KM2);
  const fields = (km2 / FIELD_KM2 / 1_000_000).toFixed(1);
  return { sp, fields };
}

function HistTooltip({ active, payload, t }) {
  if (!active || !payload || !payload.length) return null;
  const p = payload[0].payload;
  const deltaPct = p.delta == null ? null : (p.delta * 100).toFixed(1);
  return (
    <div className="dash-tooltip">
      <div className="dash-tooltip__title">{p.year}</div>
      <div className="dash-tooltip__val">{p.km2.toLocaleString('pt-BR')} km²</div>
      {deltaPct != null && (
        <div className="dash-tooltip__sub" style={{ color: colorForDelta(p.delta) }}>
          {t('dashboard.yoyDelta')}: {p.delta > 0 ? '+' : ''}{deltaPct}%
        </div>
      )}
    </div>
  );
}

export default function HistoricalTrend() {
  const { t } = useI18n();
  const [payload, setPayload] = useState(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    const ac = new AbortController();
    cachedFetch('/api/deforestation/historical', { ttl: 3600_000, signal: ac.signal })
      .then(d => setPayload(d))
      .catch(err => { if (err.name !== 'AbortError') setError(true); });
    return () => ac.abort();
  }, []);

  const data = useMemo(() => {
    if (!payload || !Array.isArray(payload.yearly)) return [];
    return buildData(payload.yearly);
  }, [payload]);

  const latest = useMemo(() => {
    if (!data.length) return null;
    const row = data[data.length - 1];
    const eq = equivalence(row.km2);
    return eq ? { year: row.year, km2: row.km2, ...eq } : null;
  }, [data]);

  return (
    <div className="chart-card chart-card--wide">
      <div className="chart-card__header">
        <h2>{t('dashboard.historicalProdes')}</h2>
        <span className="chart-card__total">{t('dashboard.historicalSub')}</span>
      </div>
      {error ? (
        <div className="dash-loading">{t('dashboard.noData')}</div>
      ) : !payload ? (
        <div className="dash-loading">{t('dashboard.loadingShort')}</div>
      ) : data.length === 0 ? (
        <div className="dash-loading">{t('dashboard.noData')}</div>
      ) : (
        <>
          {latest && (
            <div className="hist-equiv">
              <div className="hist-equiv__big">
                {latest.km2.toLocaleString('pt-BR')} km² <span className="hist-equiv__year">{latest.year}</span>
              </div>
              <div className="hist-equiv__caption">
                {t('dashboard.equivCaption', { sp: latest.sp, fields: latest.fields })}
              </div>
            </div>
          )}
          <div className="chart-canvas">
            <ResponsiveContainer width="100%" height={260}>
              <ComposedChart data={data} margin={{ top: 8, right: 16, left: 0, bottom: 0 }}>
                <CartesianGrid stroke="rgba(42, 53, 48, 0.4)" strokeDasharray="2 4" vertical={false} />
                <XAxis dataKey="year" tick={TICK_STYLE} axisLine={AXIS_LINE} tickLine={false} />
                <YAxis tick={TICK_STYLE} axisLine={AXIS_LINE} tickLine={false} width={56}
                       tickFormatter={v => v >= 1000 ? `${Math.round(v / 1000)}k` : v} />
                <Tooltip cursor={{ fill: 'rgba(255,255,255,0.04)' }} content={<HistTooltip t={t} />} />
                <Bar dataKey="km2" radius={[3, 3, 0, 0]}>
                  {data.map((d, i) => <Cell key={i} fill={colorForDelta(d.delta)} />)}
                </Bar>
                <Line
                  type="monotone"
                  dataKey="movingAvg"
                  stroke="#E8F0EC"
                  strokeWidth={1.5}
                  strokeDasharray="4 3"
                  dot={false}
                  connectNulls={false}
                />
              </ComposedChart>
            </ResponsiveContainer>
          </div>
          <div className="chart-card__attrib">
            <a href={safeHttpUrl(payload.source_url)} target="_blank" rel="noopener noreferrer">
              {payload.source || t('dashboard.attribution')}
            </a>
          </div>
        </>
      )}
    </div>
  );
}
