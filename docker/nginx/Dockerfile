FROM nginx:1.27-alpine

RUN apk add --no-cache gettext && rm -rf /etc/nginx/conf.d/default.conf

COPY docker/nginx/nginx.conf /etc/nginx/nginx.conf.template

# 환자 포털 프론트엔드 — mzclinic.cloud 환자 전용 — by 김다정, 2026-06-06
COPY app/patient/frontend/ /var/www/html/patient/
COPY app/patient/frontend/ /var/www/html/

EXPOSE 80

# 컨테이너 기동 시 ${API_KEY} 치환
CMD ["/bin/sh", "-c", "\
  envsubst '${API_KEY}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf && \
  nginx -g 'daemon off;'"]
