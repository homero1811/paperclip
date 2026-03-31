-- Fix agent instructionsFilePath pointing to wrong workspace (de8d8b2a)
-- Clear the hardcoded instructionsFilePath from all agents since agent prompts
-- already contain full instructions via the heartbeat prompt template.
-- This prevents ENOENT errors when agents run in different workspaces.

UPDATE "agents"
SET "adapter_config" = "adapter_config" - 'instructionsFilePath'
WHERE "adapter_config"->>'instructionsFilePath' IS NOT NULL
  AND "adapter_config"->>'instructionsFilePath' LIKE '%de8d8b2a%';
