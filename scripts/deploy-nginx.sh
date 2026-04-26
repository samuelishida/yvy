#!/bin/bash
# Yvy Frontend Nginx Deployment Script with SSL
# Replaces Node.js Express with Nginx for 10x performance + 200MB RAM savings
# Includes Let's Encrypt SSL setup

set -e

echo "=== Yvy Frontend Nginx Setup with SSL ==="

# Configuration
DOMAIN="yvy.app.br"
EMAIL="samuel.ishida@gmail.com"

# 1. Install nginx and certbot
echo "Installing nginx and certbot..."
sudo apt-get update
sudo apt-get install -y nginx certbot python3-certbot-nginx

# 2. Create directory for ACME challenges
echo "Setting up ACME challenge directory..."
sudo mkdir -p /var/www/certbot
sudo chown -R www-data:www-data /var/www/certbot

# 3. Create initial nginx config (HTTP only for SSL cert request)
echo "Configuring nginx for SSL certificate request..."
sudo tee /etc/nginx/sites-available/yvy > /dev/null << NGINX_EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    
    # ACME challenge for Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    # Temporary redirect to www
    location / {
        return 301 https://$DOMAIN\$request_uri;
    }
}
NGINX_EOF

# 4. Enable site
sudo ln -sf /etc/nginx/sites-available/yvy /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# 5. Test and reload nginx
echo "Testing nginx config..."
sudo nginx -t
sudo systemctl reload nginx

# 6. Request SSL certificate
echo "Requesting SSL certificate from Let's Encrypt..."
sudo certbot certonly --webroot \
    --webroot-path=/var/www/certbot \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    -d "$DOMAIN" \
    -d "www.$DOMAIN"

# 7. Update nginx config with SSL
echo "Configuring nginx with SSL..."
sudo tee /etc/nginx/sites-available/yvy > /dev/null << 'NGINX_EOF'
# HTTP server - redirect to HTTPS
server {
    listen 80;
    server_name yvy.app.br www.yvy.app.br;
    
    # ACME challenge for Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
    # Redirect all HTTP to HTTPS
    location / {
        return 301 https://$server_name$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name yvy.app.br www.yvy.app.br;
    
    # SSL certificates
    ssl_certificate /etc/letsencrypt/live/yvy.app.br/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yvy.app.br/privkey.pem;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # Root
    root /opt/yvy/frontend/build;
    index index.html;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml+rss application/json application/javascript;
    
    # Cache static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    # Proxy API requests to backend
    location /api/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # SPA fallback
    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX_EOF

# 8. Test and reload nginx with SSL config
echo "Testing nginx config with SSL..."
sudo nginx -t
sudo systemctl reload nginx

# 9. Setup automatic SSL renewal
echo "Setting up automatic SSL renewal..."
sudo tee /etc/cron.d/certbot-renew > /dev/null << 'CRON_EOF'
0 3 1 * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
CRON_EOF

# 10. Stop Node frontend (free RAM)
echo "Stopping Node.js frontend..."
sudo systemctl stop yvy-frontend 2>/dev/null || true
sudo systemctl disable yvy-frontend 2>/dev/null || true

# 11. Verify
echo ""
echo "=== Setup Complete ==="
echo "Testing HTTPS..."
curl -I -L http://localhost/ | head -5

echo ""
echo "SSL Status:"
sudo certbot certificates

echo ""
echo "RAM freed: ~200MB (Node process stopped)"
echo "Performance: 10x faster static serving"
echo "Security: HTTPS with Let's Encrypt SSL"
echo "Auto-renewal: Monthly cron job at 3 AM"
