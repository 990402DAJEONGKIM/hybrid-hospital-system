FROM nginx:1.27-alpine

RUN apk add --no-cache gettext && rm -rf /etc/nginx/conf.d/default.conf

COPY docker/nginx-onprem/nginx.conf /etc/nginx/nginx.conf

# 직원 포털 프론트엔드 (의사·간호사·관리자)
COPY app/staff/frontend/  /var/www/html/staff/
COPY app/portal/frontend/ /var/www/html/admin/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
