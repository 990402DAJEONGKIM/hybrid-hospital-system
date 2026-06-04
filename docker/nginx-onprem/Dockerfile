FROM nginx:1.27-alpine

RUN apk add --no-cache gettext && rm -rf /etc/nginx/conf.d/default.conf

# ${CORS_ALLOW_ORIGIN} placeholder를 envsubst 처리를 위해 template으로 보관
COPY docker/nginx-onprem/nginx.conf /etc/nginx/nginx.conf.template
COPY app/onprem/frontend/ /usr/share/nginx/html/

EXPOSE 80

# 컨테이너 기동 시 CORS_ALLOW_ORIGIN 환경변수를 nginx.conf에 주입
# 미설정(빈 문자열) → Access-Control-Allow-Origin: "" → CORS 비활성화 (로컬 개발)
CMD ["/bin/sh", "-c", "\
  envsubst '${CORS_ALLOW_ORIGIN}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf && \
  nginx -g 'daemon off;'"]
