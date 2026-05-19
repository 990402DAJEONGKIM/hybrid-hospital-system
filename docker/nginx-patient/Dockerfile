FROM nginx:1.27-alpine

RUN rm -rf /etc/nginx/conf.d/default.conf
COPY docker/nginx-patient/nginx.conf /etc/nginx/nginx.conf

COPY app/patient/frontend/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
