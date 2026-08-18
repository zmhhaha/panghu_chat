CREATE INDEX IF NOT EXISTS ix_follows_follower_active
  ON follows(follower_id, status, followee_id);
