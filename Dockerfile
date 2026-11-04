FROM ruby:3.3-slim

# 依存gemなし。標準ライブラリだけで動く
ENV LANG=C.UTF-8 TZ=Asia/Tokyo
WORKDIR /app
COPY bin ./bin
COPY lib ./lib
COPY public ./public

RUN mkdir -p /app/data && chown nobody:nogroup /app/data
USER nobody
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD ruby -rnet/http -e 'exit Net::HTTP.get_response(URI("http://127.0.0.1:8080/healthz")).code == "200" ? 0 : 1'
CMD ["ruby", "bin/sre-agent", "/app/config/config.yml"]
