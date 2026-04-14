FROM node:20-bookworm-slim AS ui-builder

WORKDIR /ui

COPY ui/package.json ./package.json
COPY ui/package-lock.json ./package-lock.json
COPY ui/tsconfig.json ./tsconfig.json
COPY ui/vite.config.ts ./vite.config.ts
COPY ui/index.html ./index.html
COPY ui/src ./src

RUN npm ci
RUN npm run build

FROM agnohq/python:3.12

# Environment variables that actually matter
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app

ARG USER=app
ARG APP_DIR=/app
ARG DATA_DIR=/data

# Create user
RUN groupadd -g 61000 ${USER} \
    && useradd -g 61000 -u 61000 -ms /bin/bash -d ${APP_DIR} ${USER} \
    && mkdir -p ${DATA_DIR} \
    && chown -R ${USER}:${USER} ${DATA_DIR}

WORKDIR ${APP_DIR}

# Install dependencies first (better layer caching)
COPY requirements.txt ./
RUN uv pip sync requirements.txt --system

# Copy app code
COPY --chown=${USER}:${USER} . .
COPY --from=ui-builder /ui/dist ./ui/dist

USER ${USER}

EXPOSE 8000

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["chill"]
