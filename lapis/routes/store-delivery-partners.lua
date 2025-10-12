local lapis = require("lapis")
local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local DeliveryPartnerQueries = require("queries.DeliveryPartnerQueries")
local cjson = require("cjson")
local db = require("lapis.db")

return function(app)
    -- Link delivery partner to store
    app:match("/api/v2/stores/:slug/delivery-partners", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local user_id = self.authenticated_user.id
            local store_slug = self.params.slug
            local params = self.params

            if not params.delivery_partner_uuid then
                return { status = 400, json = { error = "delivery_partner_uuid is required" } }
            end

            -- Get store and verify ownership
            local store = db.query("SELECT * FROM stores WHERE slug = ?", store_slug)[1]
            if not store then
                return { status = 404, json = { error = "Store not found" } }
            end

            if store.user_id ~= user_id then
                return { status = 403, json = { error = "You don't have permission to manage this store" } }
            end

            -- Get delivery partner
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE uuid = ?", params.delivery_partner_uuid)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner not found" } }
            end

            -- Check if already linked
            local existing = db.query([[
                SELECT * FROM store_delivery_partners
                WHERE store_id = ? AND delivery_partner_id = ?
            ]], store.id, delivery_partner.id)[1]

            if existing then
                return { status = 400, json = { error = "Delivery partner is already linked to this store" } }
            end

            -- Create link
            local link = db.insert("store_delivery_partners", {
                store_id = store.id,
                delivery_partner_id = delivery_partner.id,
                is_preferred = params.is_preferred or false,
                is_active = true,
                created_at = db.format_date()
            }, "id")

            local created_link = db.query([[
                SELECT
                    sdp.*,
                    dp.uuid as delivery_partner_uuid,
                    dp.company_name,
                    dp.contact_person_name,
                    dp.contact_person_phone,
                    dp.rating,
                    dp.total_deliveries,
                    dp.service_type,
                    dp.pricing_model,
                    dp.base_charge,
                    dp.per_km_charge,
                    dp.percentage_charge
                FROM store_delivery_partners sdp
                INNER JOIN delivery_partners dp ON sdp.delivery_partner_id = dp.id
                WHERE sdp.id = ?
            ]], link.id)[1]

            return { json = {
                message = "Delivery partner linked to store successfully",
                link = created_link
            }}
        end),

        -- Get all delivery partners linked to store
        GET = AuthMiddleware.requireAuth(function(self)
            local user_id = self.authenticated_user.id
            local store_slug = self.params.slug

            -- Get store and verify ownership
            local store = db.query("SELECT * FROM stores WHERE slug = ?", store_slug)[1]
            if not store then
                return { status = 404, json = { error = "Store not found" } }
            end

            if store.user_id ~= user_id then
                return { status = 403, json = { error = "You don't have permission to view this store's delivery partners" } }
            end

            local partners = db.query([[
                SELECT
                    sdp.id as link_id,
                    sdp.is_preferred,
                    sdp.is_active,
                    sdp.created_at as linked_at,
                    dp.id,
                    dp.uuid,
                    dp.company_name,
                    dp.contact_person_name,
                    dp.contact_person_phone,
                    dp.contact_person_email,
                    dp.service_type,
                    dp.rating,
                    dp.total_deliveries,
                    dp.successful_deliveries,
                    dp.current_active_orders,
                    dp.max_daily_capacity,
                    dp.pricing_model,
                    dp.base_charge,
                    dp.per_km_charge,
                    dp.percentage_charge,
                    dp.is_verified,
                    dp.is_active as partner_is_active
                FROM store_delivery_partners sdp
                INNER JOIN delivery_partners dp ON sdp.delivery_partner_id = dp.id
                WHERE sdp.store_id = ?
                ORDER BY sdp.is_preferred DESC, dp.rating DESC
            ]], store.id)

            return { json = { partners = partners or {} } }
        end)
    }))

    -- Remove delivery partner from store
    app:match("/api/v2/stores/:slug/delivery-partners/:partner_uuid", respond_to({
        DELETE = AuthMiddleware.requireAuth(function(self)
            local user_id = self.authenticated_user.id
            local store_slug = self.params.slug
            local partner_uuid = self.params.partner_uuid

            -- Get store and verify ownership
            local store = db.query("SELECT * FROM stores WHERE slug = ?", store_slug)[1]
            if not store then
                return { status = 404, json = { error = "Store not found" } }
            end

            if store.user_id ~= user_id then
                return { status = 403, json = { error = "You don't have permission to manage this store" } }
            end

            -- Get delivery partner
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE uuid = ?", partner_uuid)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner not found" } }
            end

            -- Check if linked
            local link = db.query([[
                SELECT * FROM store_delivery_partners
                WHERE store_id = ? AND delivery_partner_id = ?
            ]], store.id, delivery_partner.id)[1]

            if not link then
                return { status = 404, json = { error = "Delivery partner is not linked to this store" } }
            end

            -- Check if there are active orders with this partner
            local active_orders = db.query([[
                SELECT COUNT(*) as count
                FROM orders
                WHERE store_id = ? AND delivery_partner_id = ?
                AND status NOT IN ('delivered', 'cancelled', 'refunded')
            ]], store.id, delivery_partner.id)[1].count

            if active_orders > 0 then
                return { status = 400, json = {
                    error = "Cannot remove delivery partner with active orders",
                    active_orders = active_orders
                }}
            end

            -- Delete link
            db.delete("store_delivery_partners", {
                store_id = store.id,
                delivery_partner_id = delivery_partner.id
            })

            return { json = { message = "Delivery partner removed from store successfully" } }
        end)
    }))

    -- Set preferred delivery partner for store
    app:match("/api/v2/stores/:slug/delivery-partners/:partner_uuid/prefer", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local user_id = self.authenticated_user.id
            local store_slug = self.params.slug
            local partner_uuid = self.params.partner_uuid

            -- Get store and verify ownership
            local store = db.query("SELECT * FROM stores WHERE slug = ?", store_slug)[1]
            if not store then
                return { status = 404, json = { error = "Store not found" } }
            end

            if store.user_id ~= user_id then
                return { status = 403, json = { error = "You don't have permission to manage this store" } }
            end

            -- Get delivery partner
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE uuid = ?", partner_uuid)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner not found" } }
            end

            -- Check if linked
            local link = db.query([[
                SELECT * FROM store_delivery_partners
                WHERE store_id = ? AND delivery_partner_id = ?
            ]], store.id, delivery_partner.id)[1]

            if not link then
                return { status = 404, json = { error = "Delivery partner is not linked to this store" } }
            end

            -- Remove preferred status from all other partners
            db.update("store_delivery_partners", {
                is_preferred = false
            }, "store_id = ?", store.id)

            -- Set this partner as preferred
            db.update("store_delivery_partners", {
                is_preferred = true
            }, "store_id = ? AND delivery_partner_id = ?", store.id, delivery_partner.id)

            return { json = { message = "Preferred delivery partner updated successfully" } }
        end)
    }))

    -- Toggle active status of delivery partner link
    app:match("/api/v2/stores/:slug/delivery-partners/:partner_uuid/toggle", respond_to({
        PUT = AuthMiddleware.requireAuth(function(self)
            local user_id = self.authenticated_user.id
            local store_slug = self.params.slug
            local partner_uuid = self.params.partner_uuid

            -- Get store and verify ownership
            local store = db.query("SELECT * FROM stores WHERE slug = ?", store_slug)[1]
            if not store then
                return { status = 404, json = { error = "Store not found" } }
            end

            if store.user_id ~= user_id then
                return { status = 403, json = { error = "You don't have permission to manage this store" } }
            end

            -- Get delivery partner
            local delivery_partner = db.query("SELECT * FROM delivery_partners WHERE uuid = ?", partner_uuid)[1]
            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner not found" } }
            end

            -- Get link
            local link = db.query([[
                SELECT * FROM store_delivery_partners
                WHERE store_id = ? AND delivery_partner_id = ?
            ]], store.id, delivery_partner.id)[1]

            if not link then
                return { status = 404, json = { error = "Delivery partner is not linked to this store" } }
            end

            -- Toggle active status
            db.update("store_delivery_partners", {
                is_active = not link.is_active
            }, "id = ?", link.id)

            return { json = {
                message = "Delivery partner status updated successfully",
                is_active = not link.is_active
            }}
        end)
    }))
end
