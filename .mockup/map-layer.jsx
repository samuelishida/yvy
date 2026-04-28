// Faux Brazil/South America silhouette as SVG layer over map canvas
function MapSatellite() {
  return (
    <svg viewBox="0 0 800 800" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
      <defs>
        <radialGradient id="oceanGlow" cx="50%" cy="50%" r="60%">
          <stop offset="0%" stopColor="#0b3a52" />
          <stop offset="100%" stopColor="#04101f" />
        </radialGradient>
        <linearGradient id="landGreen" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#1a4a32" />
          <stop offset="50%" stopColor="#0f3826" />
          <stop offset="100%" stopColor="#0a2a1e" />
        </linearGradient>
        <pattern id="topo" width="40" height="40" patternUnits="userSpaceOnUse">
          <circle cx="20" cy="20" r="0.6" fill="rgba(45,212,255,0.06)" />
        </pattern>
        <filter id="blur1"><feGaussianBlur stdDeviation="1.2" /></filter>
      </defs>
      <rect width="800" height="800" fill="url(#oceanGlow)" />
      <rect width="800" height="800" fill="url(#topo)" />
      {/* South America silhouette - approximate */}
      <path
        d="M340 180 Q300 195 280 230 Q260 270 250 310 Q235 340 240 380 Q230 420 245 460 Q250 510 280 555 Q300 595 320 640 Q340 685 360 715 Q380 745 405 760 Q430 745 445 715 Q455 680 460 645 Q470 605 485 570 Q500 530 510 490 Q525 450 530 410 Q540 370 545 330 Q540 290 525 255 Q505 220 475 200 Q440 180 405 175 Q370 172 340 180 Z"
        fill="url(#landGreen)"
        filter="url(#blur1)"
      />
      {/* Coastline highlight */}
      <path
        d="M340 180 Q300 195 280 230 Q260 270 250 310 Q235 340 240 380 Q230 420 245 460 Q250 510 280 555 Q300 595 320 640 Q340 685 360 715 Q380 745 405 760 Q430 745 445 715 Q455 680 460 645 Q470 605 485 570 Q500 530 510 490 Q525 450 530 410 Q540 370 545 330 Q540 290 525 255 Q505 220 475 200 Q440 180 405 175 Q370 172 340 180 Z"
        fill="none"
        stroke="rgba(45,212,255,0.18)"
        strokeWidth="0.7"
      />
      {/* Amazon basin shading */}
      <ellipse cx="380" cy="320" rx="100" ry="55" fill="rgba(74,222,128,0.08)" filter="url(#blur1)" />
      <ellipse cx="400" cy="305" rx="60" ry="30" fill="rgba(74,222,128,0.06)" filter="url(#blur1)" />
      {/* Amazon river */}
      <path
        d="M280 300 Q340 310 400 320 Q450 325 490 320"
        fill="none"
        stroke="rgba(45,212,255,0.35)"
        strokeWidth="1.2"
      />
      <path
        d="M380 320 Q390 360 400 410 Q405 460 410 510"
        fill="none"
        stroke="rgba(45,212,255,0.25)"
        strokeWidth="0.9"
      />
      {/* Andes spine */}
      <path
        d="M260 280 Q255 340 270 410 Q280 480 305 550 Q315 610 335 670"
        fill="none"
        stroke="rgba(167,139,250,0.18)"
        strokeWidth="1.5"
      />
      {/* Lat/lon gridlines */}
      {[150, 250, 350, 450, 550, 650].map(y => (
        <line key={`h${y}`} x1="0" x2="800" y1={y} y2={y} stroke="rgba(255,255,255,0.025)" strokeWidth="0.5" />
      ))}
      {[150, 250, 350, 450, 550, 650].map(x => (
        <line key={`v${x}`} y1="0" y2="800" x1={x} x2={x} stroke="rgba(255,255,255,0.025)" strokeWidth="0.5" />
      ))}
    </svg>
  );
}

// Fire dots clustered over Amazon
function FireDots({ showFires }) {
  if (!showFires) return null;
  // Pre-computed positions clustered over Brazil
  const dots = React.useMemo(() => {
    const arr = [];
    const seed = 42;
    let s = seed;
    const rand = () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
    // Amazon cluster
    for (let i = 0; i < 180; i++) {
      const r = rand() * 90;
      const a = rand() * Math.PI * 2;
      arr.push({
        x: 380 + Math.cos(a) * r + (rand() - 0.5) * 30,
        y: 320 + Math.sin(a) * r * 0.7 + (rand() - 0.5) * 30,
        sz: 2 + rand() * 4,
        c: rand() > 0.85 ? 'cr' : rand() > 0.5 ? 'hi' : 'lo',
      });
    }
    // Cerrado / center
    for (let i = 0; i < 90; i++) {
      arr.push({
        x: 410 + (rand() - 0.5) * 110,
        y: 470 + (rand() - 0.5) * 90,
        sz: 2 + rand() * 3,
        c: rand() > 0.9 ? 'cr' : rand() > 0.6 ? 'hi' : 'lo',
      });
    }
    // South + scattered
    for (let i = 0; i < 50; i++) {
      arr.push({
        x: 380 + (rand() - 0.5) * 200,
        y: 580 + (rand() - 0.5) * 120,
        sz: 1.5 + rand() * 2.5,
        c: rand() > 0.8 ? 'hi' : 'lo',
      });
    }
    return arr;
  }, []);

  return (
    <svg viewBox="0 0 800 800" preserveAspectRatio="xMidYMid slice"
         style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
      {dots.map((d, i) => (
        <circle
          key={i}
          cx={d.x}
          cy={d.y}
          r={d.sz}
          fill={d.c === 'cr' ? '#ef4444' : d.c === 'hi' ? '#f97316' : '#fbbf24'}
          opacity={d.c === 'cr' ? 0.95 : d.c === 'hi' ? 0.8 : 0.55}
          style={{ filter: `drop-shadow(0 0 ${d.sz * 1.5}px ${d.c === 'cr' ? '#ef4444' : d.c === 'hi' ? '#f97316' : '#fbbf24'})` }}
        />
      ))}
    </svg>
  );
}

// Deforestation patches
function DeforestPatches({ show }) {
  if (!show) return null;
  return (
    <svg viewBox="0 0 800 800" preserveAspectRatio="xMidYMid slice"
         style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
      <g opacity="0.6">
        {[
          { x: 350, y: 290, r: 6 }, { x: 365, y: 295, r: 4 }, { x: 380, y: 285, r: 5 },
          { x: 395, y: 305, r: 7 }, { x: 410, y: 290, r: 4 }, { x: 425, y: 310, r: 5 },
          { x: 360, y: 320, r: 5 }, { x: 390, y: 330, r: 6 }, { x: 405, y: 340, r: 4 },
          { x: 440, y: 320, r: 5 }, { x: 455, y: 305, r: 4 }, { x: 470, y: 320, r: 6 },
          { x: 380, y: 360, r: 4 }, { x: 410, y: 380, r: 5 }, { x: 430, y: 365, r: 4 },
        ].map((p, i) => (
          <circle key={i} cx={p.x} cy={p.y} r={p.r}
                  fill="none" stroke="#2dd4ff" strokeWidth="0.8" opacity="0.9" />
        ))}
      </g>
    </svg>
  );
}

window.MapSatellite = MapSatellite;
window.FireDots = FireDots;
window.DeforestPatches = DeforestPatches;
