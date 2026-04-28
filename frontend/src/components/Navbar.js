import React, { useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useI18n } from '../i18n';
import logoBrazil from '../Assets/yvy_logo_brazil.svg';
import './Navbar.css';

// Modular SVG Components
const LogoTextPt = () => (
  <svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 1100 500" role="img" className="navbar-logo navbar-logo--text">
    <title>Yvy Texto</title>
    <text x="0" y="340" fill="#22d3ee" fontFamily="Outfit, sans-serif" fontSize="240" fontWeight="700">Yvy</text>
    <text x="500" y="275" fill="#4ade80" fontFamily="Outfit, sans-serif" fontSize="64" fontWeight="500">OBSERVABILIDADE</text>
    <text x="500" y="350" fill="#4ade80" fontFamily="Outfit, sans-serif" fontSize="64" fontWeight="500">AMBIENTAL</text>
  </svg>
);

const LogoTextEn = () => (
  <svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 1100 500" role="img" className="navbar-logo navbar-logo--text">
    <title>Yvy Text EN</title>
    <text x="0" y="340" fill="#22d3ee" fontFamily="Outfit, sans-serif" fontSize="240" fontWeight="700">Yvy</text>
    <text x="500" y="275" fill="#4ade80" fontFamily="Outfit, sans-serif" fontSize="64" fontWeight="500">ENVIRONMENTAL</text>
    <text x="500" y="350" fill="#4ade80" fontFamily="Outfit, sans-serif" fontSize="64" fontWeight="500">OBSERVABILITY</text>
  </svg>
);

export default function Navbar() {
  const location = useLocation();
  const [open, setOpen] = useState(false);
  const { lang, switchLang, t } = useI18n();

  const close = () => setOpen(false);

  return (
    <nav className="navbar">
      <div className="navbar-brand">
        <div className="brand-mark">
          <img src={logoBrazil} alt="Yvy Brasil" className="navbar-logo--brazil" />
        </div>
        {lang === 'pt' ? <LogoTextPt /> : <LogoTextEn />}
      </div>

      <div className={`nav-links ${open ? 'nav-links--open' : ''}`}>
        <Link
          to="/"
          className={location.pathname === '/' ? 'nav-link nav-link--active' : 'nav-link'}
          onClick={close}
        >
          <span className="nav-icon">🏠</span> {t('nav.home')}
        </Link>
        <Link
          to="/news"
          className={location.pathname === '/news' ? 'nav-link nav-link--active' : 'nav-link'}
          onClick={close}
        >
          <span className="nav-icon">📰</span> {t('nav.news')}
        </Link>
        <Link
          to="/dashboard"
          className={location.pathname === '/dashboard' ? 'nav-link nav-link--active' : 'nav-link'}
          onClick={close}
        >
          <span className="nav-icon">📊</span> {t('nav.dashboard')}
        </Link>
        <Link
          to="/mapas-tematicos"
          className={location.pathname === '/mapas-tematicos' ? 'nav-link nav-link--active' : 'nav-link'}
          onClick={close}
        >
          <span className="nav-icon">🗺️</span> {t('nav.thematicMaps')}
        </Link>
      </div>

      <div className="topbar-right">
        <div className="live-pill" aria-label="Live data">
          <span className="live-dot" />
          Live
        </div>
        <button
          className="lang-toggle"
          onClick={() => switchLang(lang === 'pt' ? 'en' : 'pt')}
          title={lang === 'pt' ? 'Switch to English' : 'Mudar para Português'}
        >
          {lang === 'pt' ? 'PT' : 'EN'}
        </button>
      </div>

      <button
        className="hamburger"
        onClick={() => setOpen((o) => !o)}
        aria-label="Toggle menu"
        aria-expanded={open}
      >
        <span className={open ? 'line line--top open' : 'line line--top'} />
        <span className={open ? 'line line--mid open' : 'line line--mid'} />
        <span className={open ? 'line line--bot open' : 'line line--bot'} />
      </button>
    </nav>
  );
}
