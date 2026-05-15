import React, { useEffect, useState } from "react";
import { useI18n } from "../../i18n";

const API_BASE = process.env.REACT_APP_API_URL || "/api";

export default function StateSparklines() {
  const { t } = useI18n();
  const [data, setData] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch(`${API_BASE}/fires/state-sparklines?days=7`)
      .then((r) => r.json())
      .then((json) => {
        const spark = json.sparklines || {};
        const rows = [];
        for (const [state, series] of Object.entries(spark)) {
          const total = series.reduce((s, d) => s + (d.count || 0), 0);
          rows.push({ state, series, total });
        }
        rows.sort((a, b) => b.total - a.total);
        setData(rows.slice(0, 12));
        setLoading(false);
      })
      .catch(() => setLoading(false));
  }, []);

  if (loading) return <div className="dash-section"><p>{t("loading")}…</p></div>;
  if (data.length === 0) return null;

  return (
    <div className="dash-section">
      <div className="sparkline-grid">
        {data.map((row) => {
          const seriesMax = Math.max(...row.series.map((d) => d.count), 1);
          return (
            <div key={row.state} className="sparkline-card">
              <div className="sparkline-header">
                <span className="sparkline-state">{row.state}</span>
                <span className="sparkline-total">{row.total.toLocaleString()}</span>
              </div>
              <div className="sparkline-bars">
                {row.series.map((d, i) => {
                  const pct = ((d.count || 0) / seriesMax) * 100;
                  return (
                    <div key={i} className="sparkline-bar-wrap" title={`${d.date}: ${d.count}`}>
                      <div className="sparkline-bar" style={{ height: `${pct}%` }} />
                    </div>
                  );
                })}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
