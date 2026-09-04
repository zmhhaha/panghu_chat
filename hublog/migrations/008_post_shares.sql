CREATE TABLE IF NOT EXISTS post_shares (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  creator_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at timestamptz,
  revoked_at timestamptz,
  access_count integer NOT NULL DEFAULT 0,
  last_accessed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_post_shares_post_created
  ON post_shares(post_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS ix_post_shares_creator_created
  ON post_shares(creator_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS ix_post_shares_public_lookup
  ON post_shares(id) WHERE revoked_at IS NULL;
