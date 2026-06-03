FROM nginx:1.27-alpine

RUN apk add --no-cache gettext && rm -rf /etc/nginx/conf.d/default.conf

COPY docker/nginx/nginx.conf /etc/nginx/nginx.conf.template

# 각 포털 프론트엔드를 도메인별 디렉토리로 복사
COPY app/staff/frontend/   /usr/share/nginx/html/staff/
COPY app/patient/frontend/ /usr/share/nginx/html/patient/
COPY app/portal/frontend/  /usr/share/nginx/html/portal/

EXPOSE 80 8002 8003 8004

CMD ["/bin/sh", "-c", "envsubst '${API_KEY}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf && nginx -g 'daemon off;'"]
