import React, { useEffect, useState } from "react";
import { useI18n } from "../../i18n";
import { Link } from "react-router-dom";

const API_BASE = process.env.REACT_APP_API_URL || "/api";

function makeMapUrl(name) {
  if (!name) return "/mapas-tematicos";
  const q = encodeURIComponent(name.trim());
  return `/mapas-tematicos?q=${q}`;
}

export default function TIAtRisk() {
  const { t } = useI18n();
  const [lands, setLands] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch(`${API_BASE}/fires/ti-at-risk?days=7&limit=10`)
      .then((r) => r.json())
      .then((json) => {
        setLands(json.lands || []);
        setLoading(false);
      })
      .catch(() => setLoading(false));
  }, []);

  if (loading) return <div className="dash-section"><p>{t("loading")}…</p></div>;
  if (lands.length === 0) return null;

  const maxCount = Math.max(...lands.map((l) => l.fire_count || 0), 1);

  return (
    <div className="dash-section">
      <div className="ti-table">
        {lands.map((l, idx) => {
          const pct = ((l.fire_count || 0) / maxCount) * 100;
          return (
            <div key={l.name || idx} className="ti-row">
              <div className="ti-rank">{idx + 1}</div>
              <div className="ti-info">
                <div className="ti-name">
                  <Link to={makeMapUrl(l.name)} className="ti-link">{l.name}</Link>
                </div>
                <div className="ti-meta">
                  {l.state_abbr || ""} · {l.fire_count} {t("fires")}
                </div>
              </div>
              <div className="ti-bar-wrap">
                <div className="ti-bar" style={{ width: `${pct}%` }} />
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
