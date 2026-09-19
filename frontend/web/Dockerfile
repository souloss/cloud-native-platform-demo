FROM nginx:1.27-alpine
ARG VITE_HYPERDX_API_KEY
ARG VITE_HYPERDX_URL
COPY dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
