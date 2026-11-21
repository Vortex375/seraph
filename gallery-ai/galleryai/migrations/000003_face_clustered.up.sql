-- false: the face still has to go through clustering (new, or clustering failed after it was stored)
ALTER TABLE faces ADD COLUMN clustered boolean NOT NULL DEFAULT false;
CREATE INDEX faces_unassigned_idx ON faces (id) WHERE person_id IS NULL AND NOT manual;
