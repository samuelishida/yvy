import React from 'react';
import { useI18n } from '../../i18n';
import { downloadCsv, downloadSvgAsPng } from '../../utils/exportData';

// Standardized card wrapper (plan: dashboard-enhancement, Inc 1/10).
// Owns the five async states so they are implemented once and cannot drift:
//   loading → spinner skeleton
//   error   → message + Retry (first consumer of invalidateApiCache)
//   empty   → "no data"
//   unavailable → "awaiting ingest from <source>" (DETER/AMS/CAR when tables are empty)
//   ready   → children
// `exportData` enables a CSV download; passing `chartRef` additionally enables PNG.

export default function CardShell({
  title,
  subtitle,
  state = 'ready',
  onRetry,
  freshness,
  exportData,
  chartRef,
  children,
}) {
  const { t } = useI18n();

  const scope = freshness
    ? typeof freshness === 'string' ? freshness : freshness.windowLabel
    : null;

  return (
    <div className="chart-card">
      <div className="chart-card__header">
        <h2>{title}</h2>
        <div className="chart-card__head-right">
          {exportData && state === 'ready' && (
            <button
              type="button"
              className="dash-export"
              onClick={() => downloadCsv(exportData.filename, exportData.rows)}
              title={t('dashboard.exportCsv')}
            >
              ⬇ CSV
            </button>
          )}
          {exportData && chartRef && state === 'ready' && (
            <button
              type="button"
              className="dash-export"
              onClick={() => {
                const svg = chartRef.current && chartRef.current.querySelector('svg');
                if (svg) downloadSvgAsPng(svg, exportData.filename.replace(/\.csv$/, '.png'));
              }}
              title={t('dashboard.exportPng')}
            >
              ⬇ PNG
            </button>
          )}
          {scope && <span className="chart-card__total">{scope}</span>}
        </div>
      </div>

      {subtitle && <p className="chart-card__sub">{subtitle}</p>}

      {state === 'loading' && (
        <div className="dash-loading">
          <span className="spinner" aria-hidden="true" />
          <span>{t('dashboard.loadingShort')}</span>
        </div>
      )}

      {state === 'error' && (
        <div className="dash-error" role="alert">
          <span>{t('dashboard.errorShort')}</span>
          {onRetry && (
            <button type="button" className="dash-retry" onClick={onRetry}>
              {t('dashboard.retry')}
            </button>
          )}
        </div>
      )}

      {state === 'empty' && <div className="dash-empty">{t('dashboard.noData')}</div>}

      {state === 'unavailable' && (
        <div className="dash-unavailable">
          {t('dashboard.unavailable')}
          {freshness && freshness.source && (
            <span className="dash-unavailable__source">{freshness.source}</span>
          )}
        </div>
      )}

      {state === 'ready' && children}
    </div>
  );
}
