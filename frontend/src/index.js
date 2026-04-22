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
];

const originalError = console.error;
console.error = (...args) => {
  const msg = args.join(' ');
  if (SUPPRESSED_PATTERNS.some((p) => p.test(msg))) return;
  originalError.apply(console, args);
};

const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
