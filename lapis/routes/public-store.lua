local respond_to = require("lapis.application").respond_to
local db = require("lapis.db")
local cjson = require("cjson")

return function(app)
    -- Get public store profile by slug
    app:match("public_store_profile", "/api/v2/public/stores/:slug", respond_to({
        GET = function(self)
            local store_slug = self.params.slug

            -- Get store with owner info
            local stores = db.query([[
                SELECT s.*,
                       u.first_name || ' ' || u.last_name as owner_name,
                       u.created_at as owner_since
                FROM stores s
                LEFT JOIN users u ON s.user_id = u.id
                WHERE s.slug = ? AND s.status = 'active'
            ]], store_slug)

            if not stores or #stores == 0 then
                return { json = { error = "Store not found" }, status = 404 }
            end

            local store = stores[1]

            -- Get product count
            local product_count = db.query([[
                SELECT COUNT(*) as count FROM storeproducts
                WHERE store_id = ? AND is_active = true
            ]], store.id)
            store.product_count = product_count[1].count or 0

            -- Get completed orders count (as a measure of sales)
            local orders_count = db.query([[
                SELECT COUNT(*) as count FROM orders
                WHERE store_id = ? AND status IN ('delivered', 'shipped')
            ]], store.id)
            store.completed_orders = orders_count[1].count or 0

            -- Get average rating (from reviews if exists)
            local avg_rating = db.query([[
                SELECT AVG(rating) as avg_rating, COUNT(*) as review_count
                FROM store_reviews
                WHERE store_id = ?
            ]], store.id)

            if avg_rating and #avg_rating > 0 then
                store.average_rating = avg_rating[1].avg_rating or 0
                store.review_count = avg_rating[1].review_count or 0
            else
                store.average_rating = 0
                store.review_count = 0
            end

            -- Remove sensitive information
            store.user_id = nil
            store.stripe_account_id = nil

            return { json = store }
        end
    }))

    -- Get store products (public)
    app:match("public_store_products", "/api/v2/public/stores/:slug/products", respond_to({
        GET = function(self)
            local store_slug = self.params.slug
            local page = tonumber(self.params.page) or 1
            local per_page = tonumber(self.params.per_page) or 20
            local category = self.params.category
            local search = self.params.search
            local sort = self.params.sort or "created_at" -- created_at, price_asc, price_desc, name
            local offset = (page - 1) * per_page

            -- Get store
            local store = db.select("* from stores where slug = ? and status = 'active'", store_slug)
            if not store or #store == 0 then
                return { json = { error = "Store not found" }, status = 404 }
            end
            local store_id = store[1].id

            -- Build query
            local where_clause = "store_id = " .. store_id .. " AND is_active = true"

            if category then
                where_clause = where_clause .. " AND category = '" .. db.escape_literal(category) .. "'"
            end

            if search and search ~= "" then
                where_clause = where_clause ..
                    " AND (name ILIKE '%" ..
                    db.escape_literal(search) .. "%' OR description ILIKE '%" .. db.escape_literal(search) .. "%')"
            end

            -- Sort mapping
            local order_by = "created_at DESC"
            if sort == "price_asc" then
                order_by = "price ASC"
            elseif sort == "price_desc" then
                order_by = "price DESC"
            elseif sort == "name" then
                order_by = "name ASC"
            end

            -- Get products
            local products = db.query([[
                SELECT * FROM storeproducts
                WHERE ]] .. where_clause .. [[
                ORDER BY ]] .. order_by .. [[
                LIMIT ]] .. per_page .. [[ OFFSET ]] .. offset)

            -- Get total count
            local total_count = db.query([[
                SELECT COUNT(*) as count FROM storeproducts
                WHERE ]] .. where_clause)

            return {
                json = {
                    products = products,
                    pagination = {
                        page = page,
                        per_page = per_page,
                        total = total_count[1].count or 0,
                        total_pages = math.ceil((total_count[1].count or 0) / per_page)
                    }
                }
            }
        end
    }))

    -- Get store reviews
    app:match("public_store_reviews", "/api/v2/public/stores/:slug/reviews", respond_to({
        GET = function(self)
            local store_slug = self.params.slug
            local page = tonumber(self.params.page) or 1
            local per_page = tonumber(self.params.per_page) or 10
            local offset = (page - 1) * per_page

            -- Get store
            local store = db.select("* from stores where slug = ? and status = 'active'", store_slug)
            if not store or #store == 0 then
                return { json = { error = "Store not found" }, status = 404 }
            end
            local store_id = store[1].id

            -- Get reviews with user info
            local reviews = db.query([[
                SELECT sr.*,
                       u.first_name,
                       u.last_name,
                       o.order_number
                FROM store_reviews sr
                LEFT JOIN users u ON sr.user_id = u.id
                LEFT JOIN orders o ON sr.order_id = o.id
                WHERE sr.store_id = ?
                ORDER BY sr.created_at DESC
                LIMIT ]] .. per_page .. [[ OFFSET ]] .. offset, store_id)

            -- Mask user names for privacy (show only first name and last initial)
            for _, review in ipairs(reviews) do
                if review.last_name then
                    review.reviewer_name = review.first_name .. " " .. string.sub(review.last_name, 1, 1) .. "."
                else
                    review.reviewer_name = review.first_name
                end
                review.first_name = nil
                review.last_name = nil
                review.user_id = nil
            end

            -- Get total count
            local total_count = db.query([[
                SELECT COUNT(*) as count FROM store_reviews
                WHERE store_id = ?
            ]], store_id)

            -- Get rating distribution
            local rating_distribution = db.query([[
                SELECT rating, COUNT(*) as count
                FROM store_reviews
                WHERE store_id = ?
                GROUP BY rating
                ORDER BY rating DESC
            ]], store_id)

            return {
                json = {
                    reviews = reviews,
                    rating_distribution = rating_distribution,
                    pagination = {
                        page = page,
                        per_page = per_page,
                        total = total_count[1].count or 0,
                        total_pages = math.ceil((total_count[1].count or 0) / per_page)
                    }
                }
            }
        end
    }))

    -- Get single product details (public)
    app:match("public_product_details", "/api/v2/public/stores/:slug/products/:product_id", respond_to({
        GET = function(self)
            local store_slug = self.params.slug
            local product_uuid = self.params.product_id

            -- Get product with store info
            local products = db.query([[
                SELECT sp.*,
                       s.name as store_name,
                       s.slug as store_slug,
                       s.uuid as store_uuid
                FROM storeproducts sp
                LEFT JOIN stores s ON sp.store_id = s.id
                WHERE sp.uuid = ? AND s.slug = ? AND sp.status = 'active'
            ]], product_uuid, store_slug)

            if not products or #products == 0 then
                return { json = { error = "Product not found" }, status = 404 }
            end

            local product = products[1]

            -- Get product reviews if review system exists
            local reviews = db.query([[
                SELECT pr.*,
                       u.first_name,
                       u.last_name
                FROM product_reviews pr
                LEFT JOIN users u ON pr.user_id = u.id
                WHERE pr.product_id = ?
                ORDER BY pr.created_at DESC
                LIMIT 5
            ]], product.id)

            if reviews then
                for _, review in ipairs(reviews) do
                    if review.last_name then
                        review.reviewer_name = review.first_name .. " " .. string.sub(review.last_name, 1, 1) .. "."
                    else
                        review.reviewer_name = review.first_name
                    end
                    review.first_name = nil
                    review.last_name = nil
                    review.user_id = nil
                end
                product.reviews = reviews
            end

            return { json = product }
        end
    }))
end
