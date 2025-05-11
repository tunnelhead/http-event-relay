FROM openresty/openresty:alpine

# Install packages
RUN apk add perl curl && opm get jkeys089/lua-resty-hmac

# Create directories
RUN mkdir -p /usr/local/openresty/lua && mkdir -p /var/www/demo

# Copy configuration and Lua scripts
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY conf/includes/ /etc/nginx/includes/
COPY conf/conf.d/default.conf /etc/nginx/conf.d/default.conf
COPY src/ /usr/local/openresty/lua/
COPY demo/ /var/www/demo

# Expose port
EXPOSE 80

# Start OpenResty
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
