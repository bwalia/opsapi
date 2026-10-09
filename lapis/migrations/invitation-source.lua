--[[
    Where a workspace invitation came from (core)
    ============================================

    namespace_invitations.source: 'admin' (sent from Members, the agent, the
    API) or 'form' (someone asked to join through a public form,
    lib/forms/targets.lua). Seats follow common practice:
      * an admin's pending invitation reserves a seat (like GitHub's pending
        invitations) until it is accepted, revoked or expires;
      * a form request reserves nothing (like Slack, people count once they
        join); the seat is checked when they accept, so a flood of requests
        can't use up the workspace or block the admins' own invitations.
    NamespaceInvitationQueries.seatsUsed / seatAvailable implement it.
]]

local db = require("lapis.db")

return {
    [1] = function()
        if not db.query("SELECT to_regclass('namespace_invitations') IS NOT NULL AS ok")[1].ok then return end
        db.query([[ALTER TABLE namespace_invitations
            ADD COLUMN IF NOT EXISTS source VARCHAR(20) NOT NULL DEFAULT 'admin']])
        db.query([[CREATE INDEX IF NOT EXISTS namespace_invitations_pending_source_idx
            ON namespace_invitations (namespace_id, source) WHERE status = 'pending']])
    end,
}
