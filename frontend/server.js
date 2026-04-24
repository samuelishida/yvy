'use strict';
const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const path = require('path');

const app = express();
const PORT = parseInt(process.env.PORT || '5001', 10);
const BACKEND_URL = process.env.BACKEND_URL || 'http://backend:5000';
const API_KEY = process.env.API_KEY || '';

// Graceful shutdown
const server = require('http').createServer(app);

function gracefulShutdown(signal) {
  console.log(`Received ${signal}. Shutting down gracefully...`);
  server.close(() => process.exit(0));
  // Force shutdown after 10s if connections still open
  setTimeout(() => process.exit(1), 10000);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// Health check (required by docker-compose healthcheck)
app.get('/health', (_req, res) => res.json({ status: 'ok' }));

// Proxy /api/* → backend, injecting API key server-side (never exposed to browser)
app.use(
  '/api',
  createProxyMiddleware({
    target: BACKEND_URL,
    changeOrigin: true,
    pathRewrite: { '^/api': '/api' },
    onProxyReq: (proxyReq) => {
      if (API_KEY) proxyReq.setHeader('X-API-Key', API_KEY);
    },
    onError: (_err, _req, res) => {
      res.status(502).json({ error: 'Backend unavailable' });
    },
  })
);

// Serve React production build
app.use(express.static(path.join(__dirname, 'build')));
app.get('*', (_req, res) => {
  res.sendFile(path.join(__dirname, 'build', 'index.html'));
});

server.listen(PORT, () => console.log(`Yvy frontend running on port ${PORT}`));
