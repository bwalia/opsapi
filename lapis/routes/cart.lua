local respond_to = require("lapis.application").respond_to
local StoreproductQueries = require("queries.StoreproductQueries")
local AuthMiddleware = require("middleware.auth")
local CartCalculator = require("lib.cart-calculator")
local db = require("lapis.db")
local cjson = require("cjson")

return function(app)
    -- Add to cart (database-based)
    app:match("add_to_cart", "/api/v2/cart/add", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local product_uuid = self.params.product_uuid
            local variant_uuid = self.params.variant_uuid
            local quantity = tonumber(self.params.quantity) or 1

            if not product_uuid then
                return { json = { error = "Product UUID required" }, status = 400 }
            end

            -- Check inventory
            local available, err = StoreproductQueries.checkInventory(product_uuid, quantity, variant_uuid)
            if not available then
                return { json = { error = err }, status = 400 }
            end
            
            -- Get user UUID from authenticated user
            if not self.current_user or not self.current_user.uuid then
                return { json = { error = "Authentication required" }, status = 401 }
            end
            local user_uuid = self.current_user.uuid
            
            -- Get user's internal ID from database
            local user_result = db.select("id from users where uuid = ?", user_uuid)
            if not user_result or #user_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_result[1].id
            
            -- Get product details
            local product = StoreproductQueries.show(product_uuid)
            if not product then
                return { json = { error = "Product not found" }, status = 404 }
            end
            
            local item_price = product.price
            local variant_title = nil
            
            -- Get variant details if specified
            if variant_uuid then
                local ProductVariantQueries = require "queries.ProductVariantQueries"
                local variant = ProductVariantQueries.show(variant_uuid)
                if not variant then
                    return { json = { error = "Variant not found" }, status = 404 }
                end
                if variant.price then
                    item_price = variant.price
                end
                variant_title = variant.title
            end
            
            -- Create cart key
            local cart_key = product_uuid
            if variant_uuid then
                cart_key = product_uuid .. "_" .. variant_uuid
            end
            
            -- Check if item already exists in cart
            local existing = db.select("* from cart_items where user_id = ? and cart_key = ?", user_id, cart_key)
            
            if existing and #existing > 0 then
                -- Update existing item
                local new_quantity = existing[1].quantity + quantity
                db.update("cart_items", {
                    quantity = new_quantity,
                    updated_at = db.format_date()
                }, "user_id = ? and cart_key = ?", user_id, cart_key)
            else
                -- Insert new item
                db.insert("cart_items", {
                    user_id = user_id,
                    cart_key = cart_key,
                    product_uuid = product_uuid,
                    variant_uuid = variant_uuid,
                    name = product.name,
                    variant_title = variant_title,
                    price = item_price,
                    quantity = quantity,
                    created_at = db.format_date(),
                    updated_at = db.format_date()
                })
            end
            
            -- Get updated cart
            local cart_items = db.select("* from cart_items where user_id = ?", user_id)
            local cart = {}
            for _, item in ipairs(cart_items) do
                cart[item.cart_key] = {
                    product_uuid = item.product_uuid,
                    variant_uuid = item.variant_uuid,
                    name = item.name,
                    variant_title = item.variant_title,
                    price = item.price,
                    quantity = item.quantity
                }
            end
            
            return { json = { message = "Added to cart", cart = cart }, status = 200 }
        end)
    }))

    -- Get cart
    app:match("get_cart", "/api/v2/cart", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user UUID from authenticated user
            if not self.current_user or not self.current_user.uuid then
                return { json = { error = "Authentication required" }, status = 401 }
            end
            local user_uuid = self.current_user.uuid
            
            -- Get user's internal ID from database
            local user_result = db.select("id from users where uuid = ?", user_uuid)
            if not user_result or #user_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_result[1].id
            
            -- Get cart items from database
            local cart_items = db.select("* from cart_items where user_id = ?", user_id)

            local cart = {}
            local items = {}
            local subtotal = 0

            for _, item in ipairs(cart_items) do
                local cart_item = {
                    product_uuid = item.product_uuid,
                    variant_uuid = item.variant_uuid,
                    name = item.name,
                    variant_title = item.variant_title,
                    price = tonumber(item.price),
                    quantity = tonumber(item.quantity)
                }

                cart[item.cart_key] = cart_item
                table.insert(items, cart_item)
                subtotal = subtotal + (cart_item.price * cart_item.quantity)
            end

            -- Calculate totals with dynamic tax and shipping
            local totals = CartCalculator.calculateCheckoutTotals(user_id)

            return { json = {
                cart = cart,
                items = items,
                subtotal = subtotal,
                total = subtotal, -- Keep backward compatibility
                totals = totals  -- New detailed totals
            }, status = 200 }
        end)
    }))

    -- Remove from cart
    app:match("remove_from_cart", "/api/v2/cart/remove/:product_uuid", respond_to({
        DELETE = AuthMiddleware.requireAuth(function(self)
            local product_uuid = self.params.product_uuid
            
            -- Get user UUID from authenticated user
            if not self.current_user or not self.current_user.uuid then
                return { json = { error = "Authentication required" }, status = 401 }
            end
            local user_uuid = self.current_user.uuid
            
            -- Get user's internal ID from database
            local user_result = db.select("id from users where uuid = ?", user_uuid)
            if not user_result or #user_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_result[1].id
            
            -- Remove all variants of this product
            db.delete("cart_items", "user_id = ? and (cart_key = ? or cart_key LIKE ?)", 
                user_id, product_uuid, product_uuid .. "_%")
            
            -- Get updated cart
            local cart_items = db.select("* from cart_items where user_id = ?", user_id)
            local cart = {}
            for _, item in ipairs(cart_items) do
                cart[item.cart_key] = {
                    product_uuid = item.product_uuid,
                    variant_uuid = item.variant_uuid,
                    name = item.name,
                    variant_title = item.variant_title,
                    price = item.price,
                    quantity = item.quantity
                }
            end
            
            return { json = { message = "Removed from cart", cart = cart }, status = 200 }
        end)
    }))

    -- Get cart totals with tax and shipping calculations
    app:match("cart_totals", "/api/v2/cart/totals", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            -- Get user UUID from authenticated user
            if not self.current_user or not self.current_user.uuid then
                return { json = { error = "Authentication required" }, status = 401 }
            end
            local user_uuid = self.current_user.uuid

            -- Get user's internal ID from database
            local user_result = db.select("id from users where uuid = ?", user_uuid)
            if not user_result or #user_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_result[1].id

            -- Calculate totals with dynamic tax and shipping
            local totals = CartCalculator.calculateCheckoutTotals(user_id)

            return { json = totals, status = 200 }
        end)
    }))

    -- Clear cart
    app:match("clear_cart", "/api/v2/cart/clear", respond_to({
        DELETE = AuthMiddleware.requireAuth(function(self)
            -- Get user UUID from authenticated user
            if not self.current_user or not self.current_user.uuid then
                return { json = { error = "Authentication required" }, status = 401 }
            end
            local user_uuid = self.current_user.uuid
            
            -- Get user's internal ID from database
            local user_result = db.select("id from users where uuid = ?", user_uuid)
            if not user_result or #user_result == 0 then
                return { json = { error = "User not found" }, status = 404 }
            end
            local user_id = user_result[1].id
            
            -- Clear all cart items for user
            db.delete("cart_items", "user_id = ?", user_id)
            
            return { json = { message = "Cart cleared" }, status = 200 }
        end)
    }))
end