-- one row: hash of the tag config (and CLIP model) photo_tags was last fully computed for;
-- '' means "unknown, re-tag at next opportunity"
CREATE TABLE tag_state (
    id          boolean PRIMARY KEY DEFAULT true CHECK (id),
    config_hash text NOT NULL
);
INSERT INTO tag_state (id, config_hash) VALUES (true, '');
