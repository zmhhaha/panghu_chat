ALTER TABLE users ADD COLUMN IF NOT EXISTS sso_subject varchar(255);
CREATE UNIQUE INDEX IF NOT EXISTS ix_users_sso_subject ON users(sso_subject) WHERE sso_subject IS NOT NULL;
