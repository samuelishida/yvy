import React, { useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import './Navbar.css';

export default function Navbar() {
  const location = useLocation();
  const [open, setOpen] = useState(false);

  const close = () => setOpen(false);

  return (
    <nav className="navbar">
      <div className="navbar-brand">
        <span className="brand-leaf">🌿</span>
        <div className="brand-text">
          <span className="brand-name">Yvy</span>
          <span className="brand-sub">Environmental Observability · Brazil</span>
        </div>
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

      <div className={`nav-links ${open ? 'nav-links--open' : ''}`}>
        <Link
          to="/"
          className={location.pathname === '/' ? 'nav-link nav-link--active' : 'nav-link'}
          onClick={close}
        >
          <span className="nav-icon">🏠</span> Home
        </Link>
        <Link
          to="/news"
          className={location.pathname === '/news' ? 'nav-link nav-link--active' : 'nav-link'}
          onClick={close}
        >
          <span className="nav-icon">📰</span> Notícias
        </Link>
        <Link
          to="/dashboard"
          className={location.pathname === '/dashboard' ? 'nav-link nav-link--active' : 'nav-link'}
          onClick={close}
        >
          <span className="nav-icon">📊</span> Dashboard
        </Link>
        <Link
          to="/mapas-tematicos"
          className={location.pathname === '/mapas-tematicos' ? 'nav-link nav-link--active' : 'nav-link'}
          onClick={close}
        >
          <span className="nav-icon">🗺️</span> Mapas Temáticos
        </Link>
      </div>

      <div className="navbar-badge">
        <span className="badge-dot" />
        <span className="badge-text">Ao vivo</span>
      </div>
    </nav>
  );
}
