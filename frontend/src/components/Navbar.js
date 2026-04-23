import React, { useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useI18n } from '../i18n';
import './Navbar.css';

export default function Navbar() {
  const location = useLocation();
  const [open, setOpen] = useState(false);
  const { lang, switchLang, t } = useI18n();

  const close = () => setOpen(false);

  return (
    <nav className="navbar">
      <div className="navbar-brand">
        <span className="brand-leaf">🌿</span>
        <div className="brand-text">
          <span className="brand-name">Yvy</span>
          <span className="brand-sub">{t('nav.brandSub')}</span>
        </div>
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

      <button
        className="lang-toggle"
        onClick={() => switchLang(lang === 'pt' ? 'en' : 'pt')}
        title={lang === 'pt' ? 'Switch to English' : 'Mudar para Português'}
      >
        {lang === 'pt' ? 'PT' : 'EN'}
      </button>

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