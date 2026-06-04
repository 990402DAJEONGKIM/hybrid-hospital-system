FROM nginx:1.27-alpine

RUN apk add --no-cache gettext && rm -rf /etc/nginx/conf.d/default.conf

COPY docker/nginx/nginx.conf /etc/nginx/nginx.conf.template

# 각 포털 프론트엔드를 경로별 디렉토리로 복사 (/var/www/html)
COPY app/patient/frontend/ /var/www/html/patient/
COPY app/staff/frontend/   /var/www/html/staff/
COPY app/portal/frontend/  /var/www/html/admin/

# staff/js/config.js: ${ONPREM_BASE_URL} placeholder를 envsubst 처리를 위해 template으로 보관
RUN mv /var/www/html/staff/js/config.js /var/www/html/staff/js/config.js.template

EXPOSE 80

# 컨테이너 기동 시:
#   1. nginx.conf: ${API_KEY} 치환
#   2. config.js:  ${ONPREM_BASE_URL} 치환 (미설정 시 빈 문자열 → 온프레미스 비활성화)
CMD ["/bin/sh", "-c", "\
  envsubst '${API_KEY}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf && \
  envsubst '${ONPREM_BASE_URL}' \
    < /var/www/html/staff/js/config.js.template \
    > /var/www/html/staff/js/config.js && \
  nginx -g 'daemon off;'"]
