CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE photos (
    provider_id text NOT NULL,
    path        text NOT NULL,
    seq         bigint NOT NULL,
    deleted     boolean NOT NULL DEFAULT false,
    model       text,
    analysed_at timestamptz,
    error       text,
    PRIMARY KEY (provider_id, path)
);

CREATE TABLE photo_embeddings (
    provider_id text NOT NULL,
    path        text NOT NULL,
    embedding   vector(512) NOT NULL,
    PRIMARY KEY (provider_id, path),
    FOREIGN KEY (provider_id, path) REFERENCES photos (provider_id, path) ON DELETE CASCADE
);
CREATE INDEX photo_embeddings_embedding_idx ON photo_embeddings USING hnsw (embedding vector_cosine_ops);

CREATE TABLE photo_tags (
    provider_id text NOT NULL,
    path        text NOT NULL,
    tag         text NOT NULL,
    score       real NOT NULL,
    PRIMARY KEY (provider_id, path, tag),
    FOREIGN KEY (provider_id, path) REFERENCES photos (provider_id, path) ON DELETE CASCADE
);
CREATE INDEX photo_tags_tag_idx ON photo_tags (tag);

CREATE TABLE persons (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text,
    cover_face_id uuid
);

CREATE TABLE faces (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider_id text NOT NULL,
    path        text NOT NULL,
    box_x1      real NOT NULL,
    box_y1      real NOT NULL,
    box_x2      real NOT NULL,
    box_y2      real NOT NULL,
    score       real NOT NULL,
    person_id   uuid REFERENCES persons (id) ON DELETE SET NULL,
    manual      boolean NOT NULL DEFAULT false,
    deferred    boolean NOT NULL DEFAULT false,
    embedding   vector(512) NOT NULL,
    FOREIGN KEY (provider_id, path) REFERENCES photos (provider_id, path) ON DELETE CASCADE
);
CREATE INDEX faces_photo_idx ON faces (provider_id, path);
CREATE INDEX faces_person_idx ON faces (person_id);
CREATE INDEX faces_embedding_idx ON faces USING hnsw (embedding vector_cosine_ops);

ALTER TABLE persons ADD FOREIGN KEY (cover_face_id) REFERENCES faces (id) ON DELETE SET NULL;
