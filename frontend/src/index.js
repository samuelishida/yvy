import React from 'react';
import ReactDOM from 'react-dom/client';
import './index.css';
import App from './App';

const SUPPRESSED_PATTERNS = [
  /Permissions-Policy.*bluetooth/i,
  /Google Maps JavaScript API/i,
  /addDomListener.*deprecated/i,
  /SearchBox is not available/i,
  /Image.*could not be loaded/i,
  /WebGL2 not supported/i,
  /ipinfo\.io/i,
  /ipapi\.co/i,
  /autheticate-title/i,
  /aria-hidden/i,
  /RetiredVersion/i,
  /terrabrasilis/i,
  /ss3-static-prod/i,
  /storyblok/i,
  /L\.Mixin\.Events/i,
  /429.*Too Many Requests/i,
];

const originalError = console.error;
console.error = (...args) => {
  const msg = args.join(' ');
  if (SUPPRESSED_PATTERNS.some((p) => p.test(msg))) return;
  originalError.apply(console, args);
};

const isCrossOriginNoise = (msg) => {
  if (!msg || typeof msg !== 'string') return false;
  return SUPPRESSED_PATTERNS.some((p) => p.test(msg));
};

window.addEventListener('error', (e) => {
  if (isCrossOriginNoise(e.message || String(e.error) || '')) {
    e.preventDefault();
  }
});

window.addEventListener('unhandledrejection', (e) => {
  const reason = String(e.reason || '');
  if (isCrossOriginNoise(reason)) {
    e.preventDefault();
  }
});

const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
