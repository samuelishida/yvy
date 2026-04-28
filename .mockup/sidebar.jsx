// Sidebar panel components

function Sparkline({ data, color = '#2dd4ff', height = 28 }) {
  const w = 200;
  const max = Math.max(...data);
  const min = Math.min(...data);
  const range = max - min || 1;
  const points = data.map((v, i) => {
    const x = (i / (data.length - 1)) * w;
    const y = height - ((v - min) / range) * height;
    return `${x},${y}`;
  }).join(' ');
  const area = `0,${height} ${points} ${w},${height}`;
  return (
    <svg viewBox={`0 0 ${w} ${height}`} className="stat-spark" preserveAspectRatio="none">
      <defs>
        <linearGradient id={`sg-${color.replace('#','')}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity="0.35" />
          <stop offset="100%" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>
      <polygon points={area} fill={`url(#sg-${color.replace('#','')})`} />
      <polyline points={points} fill="none" stroke={color} strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function GaugeRing({ value, max, color, size = 64 }) {
  const r = (size - 8) / 2;
  const c = 2 * Math.PI * r;
  const pct = Math.min(1, Math.max(0, value / max));
  return (
    <svg width={size} height={size} style={{ transform: 'rotate(-90deg)' }}>
      <circle cx={size/2} cy={size/2} r={r} fill="none" stroke="rgba(255,255,255,0.07)" strokeWidth="5" />
      <circle cx={size/2} cy={size/2} r={r} fill="none" stroke={color} strokeWidth="5"
              strokeDasharray={c} strokeDashoffset={c * (1 - pct)}
              strokeLinecap="round"
              style={{ transition: 'stroke-dashoffset 1s ease', filter: `drop-shadow(0 0 4px ${color})` }} />
    </svg>
  );
}

function HeroStats() {
  const sparkA = [12,14,11,18,22,19,28,24,32,29,38,42,39,48,45,52];
  const sparkB = [24,26,28,25,29,32,28,34,30,36,33,38,42,40,44,48];
  return (
    <div className="hero-stats">
      <div className="stat-block" style={{ '--glow': 'rgba(239,68,68,0.12)' }}>
        <div className="stat-eyebrow">
          <span style={{ width:6, height:6, borderRadius:'50%', background:'#ef4444', boxShadow:'0 0 6px #ef4444' }} />
          Focos · 24h
        </div>
        <div className="stat-value" style={{ color: '#fda4af' }}>3.686</div>
        <div className="stat-delta">▲ 18.2% vs ontem</div>
        <Sparkline data={sparkA} color="#ef4444" />
      </div>
      <div className="stat-block" style={{ '--glow': 'rgba(45,212,255,0.12)' }}>
        <div className="stat-eyebrow">
          <span style={{ width:6, height:6, borderRadius:'50%', background:'#2dd4ff', boxShadow:'0 0 6px #2dd4ff' }} />
          Desmat. · km²
        </div>
        <div className="stat-value" style={{ color: '#7dd3fc' }}>847</div>
        <div className="stat-delta down">▼ 4.1% vs ontem</div>
        <Sparkline data={sparkB} color="#2dd4ff" />
      </div>
    </div>
  );
}

function BiomePanel() {
  const biomes = [
    { name: 'Amazônia',     pct: 78, val: '2.871', color: 'linear-gradient(90deg,#ef4444,#f97316)' },
    { name: 'Cerrado',      pct: 54, val: '512',   color: 'linear-gradient(90deg,#fb923c,#fbbf24)' },
    { name: 'Caatinga',     pct: 32, val: '184',   color: 'linear-gradient(90deg,#fbbf24,#facc15)' },
    { name: 'Mata Atl.',    pct: 24, val: '78',    color: 'linear-gradient(90deg,#a78bfa,#c4b5fd)' },
    { name: 'Pantanal',     pct: 18, val: '32',    color: 'linear-gradient(90deg,#2dd4ff,#67e8f9)' },
    { name: 'Pampa',        pct: 6,  val: '9',     color: 'linear-gradient(90deg,#4ade80,#86efac)' },
  ];
  return (
    <div className="panel">
      <div className="panel-header">
        <div className="panel-title">
          <span className="panel-icon">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M12 2L2 22h20L12 2z"/>
            </svg>
          </span>
          <span className="panel-title-text">Focos por bioma</span>
        </div>
        <span className="panel-meta">24H · BR</span>
      </div>
      <div className="panel-body" style={{ paddingTop: 4, paddingBottom: 8 }}>
        {biomes.map((b, i) => (
          <div key={i} className="biome-row">
            <div className="biome-name">{b.name}</div>
            <div className="biome-bar">
              <div className="biome-bar-fill" style={{ width: `${b.pct}%`, background: b.color }} />
            </div>
            <div className="biome-val">{b.val}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

function AlertsPanel() {
  const alerts = [
    { tick: 'crit', title: 'Cluster de alta confiança', meta: 'Pará · Novo Progresso', state: 'PA · 14 focos', ts: '02m' },
    { tick: 'warn', title: 'Avanço de queimada noturna', meta: 'Mato Grosso · Querência', state: 'MT · 8 focos',  ts: '11m' },
    { tick: 'crit', title: 'Foco em Terra Indígena',    meta: 'Rondônia · Karipuna',    state: 'RO · 3 focos',  ts: '23m' },
    { tick: 'info', title: 'Polígono PRODES atualizado', meta: 'Amazonas · Lábrea',     state: 'AM · 12 km²',   ts: '47m' },
    { tick: 'warn', title: 'PM2.5 acima do limiar',     meta: 'Acre · Rio Branco',     state: 'AC · 138 µg/m³', ts: '1h' },
  ];
  return (
    <div className="panel">
      <div className="panel-header">
        <div className="panel-title">
          <span className="panel-icon" style={{ color: '#fb923c' }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83"/>
            </svg>
          </span>
          <span className="panel-title-text">Alertas ao vivo</span>
        </div>
        <span className="panel-meta">5 ATIVOS</span>
      </div>
      <div className="panel-body" style={{ paddingTop: 4, paddingBottom: 8 }}>
        {alerts.map((a, i) => (
          <div key={i} className="alert-row">
            <div className={`alert-tick ${a.tick}`} />
            <div className="alert-body">
              <div className="alert-title">
                <span>{a.title}</span>
                <span className="ts">{a.ts}</span>
              </div>
              <div className="alert-meta">
                {a.meta} <span className="sep">/</span> {a.state}
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

window.HeroStats = HeroStats;
window.BiomePanel = BiomePanel;
window.AlertsPanel = AlertsPanel;
window.GaugeRing = GaugeRing;
window.Sparkline = Sparkline;
