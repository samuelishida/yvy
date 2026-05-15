import React from 'react';
import { useI18n } from '../../i18n';

const BIOMES = ['Amazônia', 'Cerrado', 'Mata Atlântica', 'Caatinga', 'Pantanal', 'Pampa'];
const BIOME_COLORS = {
  'Amazônia':       '#ef4444',
  'Cerrado':        '#fb923c',
  'Mata Atlântica': '#a78bfa',
  'Caatinga':       '#fbbf24',
  'Pantanal':       '#2dd4ff',
  'Pampa':          '#4ade80',
};
const RANGES = [
  { days: 7,  tKey: 'dashboard.range7d' },
  { days: 30, tKey: 'dashboard.range30d' },
  { days: 90, tKey: 'dashboard.range90d' },
];

export default function DashboardFilters({ selectedBiome, onBiomeChange, rangeDays, onRangeChange }) {
  const { t } = useI18n();
  return (
    <div className="dash-filters">
      <div className="dash-filters__group">
        <span className="dash-filters__label">{t('dashboard.filterByBiome')}</span>
        <div className="chip-row">
          {BIOMES.map(b => {
            const active = selectedBiome === b;
            return (
              <button
                key={b}
                type="button"
                className={`chip${active ? ' chip--active' : ''}`}
                style={{ '--chip-color': BIOME_COLORS[b] }}
                onClick={() => onBiomeChange(active ? null : b)}
              >
                <span className="chip-swatch" style={{ background: BIOME_COLORS[b] }} />
                {b}
              </button>
            );
          })}
          {selectedBiome && (
            <button
              type="button"
              className="chip chip--clear"
              onClick={() => onBiomeChange(null)}
            >
              {t('dashboard.clearFilters')}
            </button>
          )}
        </div>
      </div>
      <div className="dash-filters__group">
        <span className="dash-filters__label">{t('dashboard.filterRange')}</span>
        <div className="chip-row">
          {RANGES.map(r => {
            const active = rangeDays === r.days;
            return (
              <button
                key={r.days}
                type="button"
                className={`chip chip--range${active ? ' chip--active' : ''}`}
                onClick={() => onRangeChange(r.days)}
              >
                {t(r.tKey)}
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
