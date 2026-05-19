FROM nginx:1.27-alpine

RUN rm -rf /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/nginx.conf

# 의료진 포털 정적 파일 번들
COPY ../../app/staff/frontend/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
