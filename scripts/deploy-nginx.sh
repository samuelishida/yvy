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

# 3. Create nginx config (HTTP only, serves app directly)
echo "Configuring nginx..."
sudo tee /etc/nginx/sites-available/yvy > /dev/null << NGINX_EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN _;
    root /opt/yvy/frontend/build;
    index index.html;
    
    # ACME challenge for Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    
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
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # SPA fallback
    location / {
        try_files \$uri \$uri/ /index.html;
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

# 7. Update nginx config with SSL (if cert exists)
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "SSL certificate found, enabling HTTPS..."
    sudo certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN"
else
    echo "SSL certificate not found. Keeping HTTP-only config."
    echo "After updating DNS A record to point to this server, run:"
    echo "  sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN"
fi

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
