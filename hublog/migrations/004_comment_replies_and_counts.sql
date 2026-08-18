ALTER TABLE comments
  ADD COLUMN IF NOT EXISTS parent_comment_id uuid REFERENCES comments(id) ON DELETE SET NULL;

ALTER TABLE comments
  ADD COLUMN IF NOT EXISTS reply_to_user_id uuid REFERENCES users(id) ON DELETE RESTRICT;

CREATE INDEX IF NOT EXISTS ix_comments_parent_created
  ON comments(parent_comment_id, created_at DESC, id DESC);

ALTER TABLE posts
  ADD COLUMN IF NOT EXISTS comment_count integer NOT NULL DEFAULT 0;

UPDATE posts AS post
SET comment_count = (
  SELECT count(*)::integer
  FROM comments AS comment
  WHERE comment.post_id = post.id
    AND comment.status = 'published'
);
