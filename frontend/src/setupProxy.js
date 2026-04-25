const { createProxyMiddleware } = require('http-proxy-middleware');

module.exports = function(app) {
  app.use(
    '/api',
    createProxyMiddleware({
      target: process.env.REACT_APP_BACKEND_URL || 'http://localhost:5000',
      changeOrigin: true,
      pathRewrite: {
        '^/api': '/api',
      },
      onProxyReq: (proxyReq) => {
        const apiKey = process.env.REACT_APP_API_KEY || process.env.API_KEY || '';
        if (apiKey) {
          proxyReq.setHeader('X-API-Key', apiKey);
        }
      },
    })
  );
};
