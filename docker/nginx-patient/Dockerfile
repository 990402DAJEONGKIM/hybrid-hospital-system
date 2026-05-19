FROM nginx:1.27-alpine

# 기본 nginx 설정 제거 후 커스텀 설정 적용
RUN rm -rf /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/nginx.conf

# 환자 포털 정적 파일 번들
COPY ../../app/patient/frontend/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
