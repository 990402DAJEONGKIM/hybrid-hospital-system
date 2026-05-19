FROM nginx:1.27-alpine

RUN rm -rf /etc/nginx/conf.d/default.conf
COPY docker/nginx-staff/nginx.conf /etc/nginx/nginx.conf

COPY app/staff/frontend/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
