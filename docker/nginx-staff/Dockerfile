FROM nginx:1.27-alpine

RUN apk add --no-cache gettext && rm -rf /etc/nginx/conf.d/default.conf
COPY docker/nginx-staff/nginx.conf /etc/nginx/nginx.conf.template
COPY app/staff/frontend/ /usr/share/nginx/html/

EXPOSE 80

# envsubst '${API_KEY}' 는 ${API_KEY} 만 치환하고 nginx 변수($remote_addr 등)는 보존
CMD ["/bin/sh", "-c", "envsubst '${API_KEY}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf && nginx -g 'daemon off;'"]
