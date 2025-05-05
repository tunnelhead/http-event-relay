FROM openresty/openresty:alpine

# Create directories
RUN mkdir -p /usr/local/openresty/lua

# Copy configuration and Lua scripts
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY conf/conf.d/default.conf /etc/nginx/conf.d/default.conf
COPY src/ /usr/local/openresty/lua/

# Expose port
EXPOSE 80

# Start OpenResty
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
