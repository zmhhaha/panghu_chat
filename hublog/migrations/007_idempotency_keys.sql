CREATE TABLE IF NOT EXISTS idempotency_keys (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  key varchar(255) NOT NULL,
  request_hash varchar(64) NOT NULL,
  post_id uuid NOT NULL UNIQUE REFERENCES posts(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, key)
);
CREATE INDEX IF NOT EXISTS ix_idempotency_keys_post ON idempotency_keys(post_id);
