'use strict';
const express = require('express');
const http = require('http');
const https = require('https');
const path = require('path');

const app = express();
const PORT = parseInt(process.env.PORT || '5001', 10);
const BACKEND_URL = process.env.BACKEND_URL || 'http://127.0.0.1:5000';
const API_KEY = process.env.API_KEY || '';
const backendBase = new URL(BACKEND_URL);
const backendTransport = backendBase.protocol === 'https:' ? https : http;
const backendAgent =
  backendBase.protocol === 'https:'
    ? new https.Agent({ keepAlive: false })
    : new http.Agent({ keepAlive: false });

// Graceful shutdown
const server = http.createServer(app);

function gracefulShutdown(signal) {
  console.log(`Received ${signal}. Shutting down gracefully...`);
  server.close(() => process.exit(0));
  // Force shutdown after 10s if connections still open
  setTimeout(() => process.exit(1), 10000);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// Health check endpoint
app.get('/health', (_req, res) => res.json({ status: 'ok' }));

// Forward /api/* → backend, injecting API key server-side (never exposed to browser)
app.use('/api', (req, res) => {
  const headers = { ...req.headers };
  delete headers.host;
  delete headers.connection;
  delete headers['proxy-connection'];
  headers.host = backendBase.host;
  headers.connection = 'close';
  if (API_KEY) headers['x-api-key'] = API_KEY;

  const proxyReq = backendTransport.request(
    {
      protocol: backendBase.protocol,
      hostname: backendBase.hostname,
      port: backendBase.port || (backendBase.protocol === 'https:' ? 443 : 80),
      method: req.method,
      path: req.originalUrl,
      headers,
      agent: backendAgent,
      timeout: 30000,
    },
    (proxyRes) => {
      res.status(proxyRes.statusCode || 502);
      for (const [key, value] of Object.entries(proxyRes.headers)) {
        if (value !== undefined && key.toLowerCase() !== 'connection') {
          res.setHeader(key, value);
        }
      }
      proxyRes.pipe(res);
    }
  );

  proxyReq.on('timeout', () => {
    proxyReq.destroy(new Error('Proxy timeout'));
  });

  proxyReq.on('error', (err) => {
    console.error(`[proxy] ${req.method} ${req.originalUrl} -> ${err.code || err.message}`);
    if (!res.headersSent) {
      res.status(502).json({ error: 'Backend unavailable' });
    } else {
      res.end();
    }
  });

  req.pipe(proxyReq);
});

// Serve React production build
app.use(express.static(path.join(__dirname, 'build')));
app.get('*', (_req, res) => {
  res.sendFile(path.join(__dirname, 'build', 'index.html'));
});

server.listen(PORT, () => console.log(`Yvy frontend running on port ${PORT}`));
