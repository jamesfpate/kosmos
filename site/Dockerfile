# The website as a tiny static server (published to ghcr.io/jamesfpate/winnow-site by the Site workflow; the homelab
# runs it behind the Cloudflare tunnel at winnow.jamespate.net).
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html privacy.html icon.png latest.json /usr/share/nginx/html/
COPY img /usr/share/nginx/html/img
