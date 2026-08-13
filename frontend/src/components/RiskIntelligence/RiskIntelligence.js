import React, { useState, useCallback, useEffect, useRef } from 'react';
import { useI18n } from '../../i18n';
import './RiskIntelligence.css';

// Risk Intelligence page (plan: risk-intelligence, Inc 5).
// Upload CSV raw (Content-Type: text/csv, no FormData) → POST /api/risk/batch
// → poll GET /api/risk/batch?id=<id> → results table with score badges →
// download PDF via window.open('/api/risk/report?id=...'). AlertsTab consumes
// GET /api/risk/supplier-alerts (Inc 6).

const LEVEL_CLASS = {
  alto: 'risk-badge risk-badge--alto',
  medio: 'risk-badge risk-badge--medio',
  baixo: 'risk-badge risk-badge--baixo',
  unknown: 'risk-badge risk-badge--unknown',
};

function ScoreBadge({ level, score }) {
  const { t } = useI18n();
  const cls = LEVEL_CLASS[level] || 'risk-badge risk-badge--baixo';
  return (
    <span className={cls} title={t(`risk.level${level[0].toUpperCase()}${level.slice(1)}`)}>
      {score}
    </span>
  );
}

// Pillar bars (Severity / Legality / Evidence) + Confidence %. Nil pillars
// render as 0 (partial evidence) gracefully.
function PillarBars({ pillars }) {
  const { t } = useI18n();
  if (!pillars) return <span className="risk-table__pillars risk-table__pillars--empty">—</span>;
  const items = [
    { key: 'severity', label: t('risk.pillarSeverity') },
    { key: 'legality', label: t('risk.pillarLegality') },
    { key: 'evidence', label: t('risk.pillarEvidence') },
  ];
  return (
    <span className="risk-table__pillars">
      {items.map((it) => {
        const val = pillars[it.key] != null ? pillars[it.key] : 0;
        const pct = Math.round(val * 100);
        return (
          <span key={it.key} className="risk-table__pillar" title={`${it.label}: ${pct}%`}>
            <span className="risk-table__pillar-label">{it.label}</span>
            <span className="risk-table__pillar-bar">
              <span className="risk-table__pillar-fill" style={{ width: `${pct}%` }} />
            </span>
            <span className="risk-table__pillar-val">{pct}%</span>
          </span>
        );
      })}
    </span>
  );
}

// PDF download (fixup Inc 1): GET /api/risk/report → 202 {report_id}, poll
// /api/risk/report/status until ready, then window.open the download URL.
function PdfButton({ propertyId }) {
  const { t } = useI18n();
  const [state, setState] = useState('idle'); // idle | generating | error
  const [error, setError] = useState(null);
  const pollRef = useRef(null);

  const download = useCallback(async () => {
    if (state === 'generating') return;
    setState('generating');
    setError(null);
    let cancelled = false;
    try {
      const res = await fetch(`/api/risk/report?id=${encodeURIComponent(propertyId)}`);
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(data.error || `HTTP ${res.status}`);
      }
      const { report_id } = await res.json();
      const poll = async () => {
        try {
          const sres = await fetch(`/api/risk/report/status?id=${encodeURIComponent(report_id)}`);
          if (!sres.ok) throw new Error(`HTTP ${sres.status}`);
          const sdata = await sres.json();
          if (cancelled) return;
          if (sdata.status === 'ready' && sdata.url) {
            setState('idle');
            window.open(sdata.url, '_blank', 'noopener,noreferrer');
            return;
          }
          if (sdata.status === 'failed') {
            setState('error');
            setError(t('risk.reportFailed'));
            return;
          }
          pollRef.current = setTimeout(poll, 1500);
        } catch (err) {
          if (cancelled) return;
          setState('error');
          setError(err.message || t('risk.reportFailed'));
        }
      };
      poll();
    } catch (err) {
      if (cancelled) return;
      setState('error');
      setError(err.message || t('risk.reportFailed'));
    }
    return () => {
      cancelled = true;
      if (pollRef.current) clearTimeout(pollRef.current);
    };
  }, [propertyId, t, state]);

  useEffect(() => () => {
    if (pollRef.current) clearTimeout(pollRef.current);
  }, []);

  if (state === 'generating') {
    return <span className="risk-table__pdf risk-table__pdf--busy">{t('risk.reportGenerating')}</span>;
  }
  if (state === 'error') {
    return (
      <span className="risk-table__pdf">
        <button className="risk-table__pdf-btn" onClick={download}>{t('risk.downloadPdf')}</button>
        <span className="risk-table__pdf-error" title={error}>!</span>
      </span>
    );
  }
  return (
    <button className="risk-table__pdf-btn" onClick={download}>{t('risk.downloadPdf')}</button>
  );
}

function UploadForm({ onUploaded }) {
  const { t } = useI18n();
  const [csvText, setCsvText] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const handleSubmit = useCallback(async (e) => {
    e.preventDefault();
    if (!csvText.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const res = await fetch('/api/risk/batch', {
        method: 'POST',
        headers: { 'Content-Type': 'text/csv' },
        body: csvText,
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        throw new Error(data.error || `HTTP ${res.status}`);
      }
      const data = await res.json();
      onUploaded(data.batch_id);
    } catch (err) {
      setError(err.message || t('risk.uploadError'));
    } finally {
      setBusy(false);
    }
  }, [csvText, onUploaded, t]);

  return (
    <form className="risk-upload" onSubmit={handleSubmit}>
      <label className="risk-upload__label">{t('risk.uploadCsv')}</label>
      <textarea
        className="risk-upload__input"
        value={csvText}
        onChange={(e) => setCsvText(e.target.value)}
        placeholder={t('risk.uploadHint')}
        rows={6}
      />
      {error && <div className="risk-upload__error">{error}</div>}
      <button type="submit" className="risk-upload__btn" disabled={busy || !csvText.trim()}>
        {busy ? t('risk.uploading') : t('risk.uploadBtn')}
      </button>
    </form>
  );
}

function ResultsTable({ batchId }) {
  const { t } = useI18n();
  const [state, setState] = useState('running');
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const pollRef = useRef(null);

  useEffect(() => {
    if (!batchId) return undefined;
    let cancelled = false;
    const poll = async () => {
      try {
        const res = await fetch(`/api/risk/batch?id=${encodeURIComponent(batchId)}`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const d = await res.json();
        if (cancelled) return;
        setData(d);
        if (d.status === 'done') {
          setState('done');
          return;
        }
        if (d.status === 'failed') {
          setState('error');
          setError(d.error || t('risk.batchError'));
          return;
        }
        // still running → poll again
        pollRef.current = setTimeout(poll, 2000);
      } catch (err) {
        if (cancelled) return;
        setState('error');
        setError(err.message || t('risk.batchError'));
      }
    };
    setState('running');
    poll();
    return () => {
      cancelled = true;
      if (pollRef.current) clearTimeout(pollRef.current);
    };
  }, [batchId, t]);

  if (state === 'running') {
    const processed = (data && data.processed) || 0;
    const total = (data && data.total) || 0;
    return (
      <div className="risk-results">
        <h2 className="risk-results__title">{t('risk.results')}</h2>
        <div className="risk-results__status">
          {t('risk.batchRunning', { processed, total })}
        </div>
      </div>
    );
  }

  if (state === 'error') {
    return (
      <div className="risk-results">
        <h2 className="risk-results__title">{t('risk.results')}</h2>
        <div className="risk-results__error">{error}</div>
      </div>
    );
  }

  const results = (data && data.results) || [];
  if (results.length === 0) {
    return (
      <div className="risk-results">
        <h2 className="risk-results__title">{t('risk.results')}</h2>
        <div className="risk-results__empty">{t('risk.noResults')}</div>
      </div>
    );
  }

  // Default sort: UNKNOWN rows rank last; among same-score rows, higher
  // confidence ranks higher. `confidence` may be undefined on legacy payloads
  // → treat as 0 so legacy rows sink below scored rows.
  const sorted = [...results].sort((a, b) => {
    const aU = a.unknown ? 1 : 0;
    const bU = b.unknown ? 1 : 0;
    if (aU !== bU) return aU - bU;
    if ((b.score || 0) !== (a.score || 0)) return (b.score || 0) - (a.score || 0);
    return (b.confidence || 0) - (a.confidence || 0);
  });

  return (
    <div className="risk-results">
      <h2 className="risk-results__title">
        {t('risk.results')} · {t('risk.batchDone', { total: results.length })}
      </h2>
      <table className="risk-table">
        <thead>
          <tr>
            <th>{t('risk.property')}</th>
            <th>{t('risk.areaEfetiva')}</th>
            <th>{t('risk.score')}</th>
            <th>{t('risk.level')}</th>
            <th>{t('risk.confidence')}</th>
            <th>{t('risk.pillars')}</th>
            <th>{t('risk.recommendation')}</th>
            <th>{t('risk.downloadPdf')}</th>
          </tr>
        </thead>
        <tbody>
          {sorted.map((r) => (
            <tr key={r.property_id}>
              <td>{r.nome || r.property_id}</td>
              <td className="risk-table__area">
                {r.area_efetiva_ha != null ? `${Number(r.area_efetiva_ha).toFixed(1)}` : '—'}
              </td>
              <td><ScoreBadge level={r.level} score={r.score} /></td>
              <td>{t(`risk.level${r.level[0].toUpperCase()}${r.level.slice(1)}`)}</td>
              <td className="risk-table__conf">
                {r.confidence != null ? `${r.confidence}%` : '—'}
              </td>
              <td><PillarBars pillars={r.pillars} /></td>
              <td className="risk-table__rec">{r.recommendation}</td>
              <td>
                <PdfButton propertyId={r.property_id} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AlertsTab() {
  const { t } = useI18n();
  const [alerts, setAlerts] = useState([]);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    let cancelled = false;
    fetch('/api/risk/supplier-alerts')
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((d) => {
        if (cancelled) return;
        setAlerts((d && d.alerts) || []);
        setLoaded(true);
      })
      .catch(() => {
        if (!cancelled) setLoaded(true);
      });
    return () => { cancelled = true; };
  }, []);

  if (!loaded) return <div className="risk-alerts risk-alerts--loading" />;
  if (alerts.length === 0) {
    return <div className="risk-alerts risk-alerts--empty">{t('risk.noAlerts')}</div>;
  }
  return (
    <div className="risk-alerts">
      <table className="risk-table">
        <thead>
          <tr>
            <th>{t('risk.supplier')}</th>
            <th>{t('risk.alertDate')}</th>
            <th>{t('risk.alertArea')}</th>
            <th>{t('risk.alertBiome')}</th>
            <th>{t('risk.alertState')}</th>
          </tr>
        </thead>
        <tbody>
          {alerts.map((a, i) => (
            <tr key={i}>
              <td>{a.nome || a.cnpj}</td>
              <td>{a.data_deteccao || a.at}</td>
              <td>{a.area_ha}</td>
              <td>{a.biome}</td>
              <td>{a.state}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default function RiskIntelligence() {
  const { t } = useI18n();
  const [batchId, setBatchId] = useState(null);
  const [tab, setTab] = useState('batch');

  const handleUploaded = useCallback((id) => {
    setBatchId(id);
    setTab('batch');
  }, []);

  return (
    <div className="risk-page">
      <header className="risk-page__header">
        <h1>{t('risk.title')}</h1>
        <p>{t('risk.subtitle')}</p>
      </header>

      <div className="risk-tabs">
        <button
          type="button"
          className={tab === 'batch' ? 'risk-tab risk-tab--active' : 'risk-tab'}
          onClick={() => setTab('batch')}
        >
          {t('risk.uploadCsv')}
        </button>
        <button
          type="button"
          className={tab === 'alerts' ? 'risk-tab risk-tab--active' : 'risk-tab'}
          onClick={() => setTab('alerts')}
        >
          {t('risk.alertsTab')}
        </button>
      </div>

      {tab === 'batch' ? (
        <div className="risk-page__body">
          <UploadForm onUploaded={handleUploaded} />
          {batchId && <ResultsTable batchId={batchId} />}
        </div>
      ) : (
        <AlertsTab />
      )}
    </div>
  );
}
