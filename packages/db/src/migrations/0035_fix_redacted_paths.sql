-- Fix corrupted comment paths where /paperclip was redacted to []
-- This happened because redactCurrentUserText() was applied to comment body content
-- See: fix: stop redacting paths in comment/document body content

UPDATE "issue_comments"
SET "body" = REPLACE("body", '[]/', '/paperclip/')
WHERE "body" LIKE '%[]/%';

UPDATE "approval_comments"
SET "body" = REPLACE("body", '[]/', '/paperclip/')
WHERE "body" LIKE '%[]/%';
