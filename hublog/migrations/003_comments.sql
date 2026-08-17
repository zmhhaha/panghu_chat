CREATE TABLE IF NOT EXISTS comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  content text NOT NULL,
  status varchar(16) NOT NULL DEFAULT 'published',
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE INDEX IF NOT EXISTS ix_comments_post_created ON comments(post_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS ix_comments_author_created ON comments(author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_comments_status_created ON comments(status, created_at DESC);
