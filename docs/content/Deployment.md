# Deployment

## Checklist

### Server

- [ ] Generate strong JWT secrets (`openssl rand -hex 64` × 2)
- [ ] Set up MongoDB Atlas or self-hosted MongoDB with authentication
- [ ] Deploy Coturn or configure a managed TURN service
- [ ] Obtain SSL certificate (Let's Encrypt via certbot)
- [ ] Update `nginx.conf` with your domain name
- [ ] Set `ALLOWED_ORIGINS` to your app's domain
- [ ] Verify the Rust server with `cargo test` if using the Rust backend

### Flutter / Android

- [ ] Update `lib/core/constants.dart` with production URLs
- [ ] Update `AndroidManifest.xml` deep link domain
- [ ] Update `network_security_config.xml` with your domain
- [ ] Enable `android:usesCleartextTraffic="false"` in `AndroidManifest.xml`
- [ ] Consider certificate pinning in `network_security_config.xml`
- [ ] Set `flutter build apk --release` or `flutter build appbundle --release`

### Testing

- [ ] Test calls on real devices over different networks (not just same WiFi)
- [ ] Test call through a mobile hotspot (exercises STUN/TURN)
- [ ] Test background notifications (Firebase FCM)
- [ ] Verify DTLS fingerprints match in-app
- [ ] Test token refresh flow (wait 15 min or reduce `JWT_ACCESS_EXPIRY`)

## Nginx Configuration

```nginx
server {
    listen 443 ssl;
    server_name yourapp.com;

    ssl_certificate     /etc/letsencrypt/live/yourapp.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourapp.com/privkey.pem;

    # WebSocket proxy
    location /ws {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
    }

    # REST API
    location /api {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Docker Compose (Production)

```yaml
version: '3.8'
services:
  app:
    build: .
    environment:
      - MONGODB_URI=mongodb://mongo:27017/voicecall
      - JWT_ACCESS_SECRET=${JWT_ACCESS_SECRET}
      - JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}
      - NODE_ENV=production
    restart: unless-stopped

  mongo:
    image: mongo:7
    volumes:
      - mongo_data:/data/db
    restart: unless-stopped

  nginx:
    image: nginx:alpine
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on: [app]
    restart: unless-stopped

volumes:
  mongo_data:
```
