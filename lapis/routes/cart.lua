local respond_to = require("lapis.application").respond_to
local StoreproductQueries = require("queries.StoreproductQueries")

return function(app)
    -- Add to cart (session-based)
    app:match("add_to_cart", "/api/v2/cart/add", respond_to({
        POST = function(self)
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

            -- Get cart from cookie (simplified approach)
            local cart = {}
            local json = require("cjson")

            local cart_cookie = ngx.var.cookie_cart
            if cart_cookie then
                local ok, decoded = pcall(json.decode, ngx.unescape_uri(cart_cookie))
                if ok and type(decoded) == "table" then
                    cart = decoded
                end
            end

            -- Create unique cart key for product+variant combination
            local cart_key = product_uuid
            if variant_uuid then
                cart_key = product_uuid .. "_" .. variant_uuid
            end

            -- Add/update item in cart
            if cart[cart_key] then
                cart[cart_key].quantity = cart[cart_key].quantity + quantity
            else
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

                cart[cart_key] = {
                    product_uuid = product_uuid,
                    variant_uuid = variant_uuid,
                    name = product.name,
                    variant_title = variant_title,
                    price = item_price,
                    quantity = quantity
                }
            end

            -- Save to cookie
            local cart_json = json.encode(cart)
            ngx.header["Set-Cookie"] = "cart=" .. ngx.escape_uri(cart_json) ..
                "; Path=/; Max-Age=604800; SameSite=None; Secure=false"

            return { json = { message = "Added to cart", cart = cart }, status = 200 }
        end
    }))

    -- Get cart
    app:match("get_cart", "/api/v2/cart", respond_to({
        GET = function(_self)
            local cart = {}
            local json = require("cjson")

            -- Get from cookie
            local cart_cookie = ngx.var.cookie_cart
            if cart_cookie then
                local ok, decoded = pcall(json.decode, ngx.unescape_uri(cart_cookie))
                if ok and type(decoded) == "table" then
                    cart = decoded
                end
            end

            local total = 0
            local items = {}
            for _, item in pairs(cart) do
                if type(item) == "table" and item.price and item.quantity then
                    total = total + (tonumber(item.price) * tonumber(item.quantity))
                    table.insert(items, item)
                end
            end

            return { json = { cart = cart, items = items, total = total }, status = 200 }
        end
    }))

    -- Remove from cart
    app:match("remove_from_cart", "/api/v2/cart/remove/:product_uuid", respond_to({
        DELETE = function(self)
            local product_uuid = self.params.product_uuid
            local cart = {}
            local json = require("cjson")

            -- Get current cart from cookie
            local cart_cookie = ngx.var.cookie_cart
            if cart_cookie then
                local ok, decoded = pcall(json.decode, ngx.unescape_uri(cart_cookie))
                if ok and type(decoded) == "table" then
                    cart = decoded
                end
            end

            -- Remove all variants of this product
            for key, _ in pairs(cart) do
                if key == product_uuid or key:match("^" .. product_uuid .. "_") then
                    cart[key] = nil
                end
            end

            -- Save updated cart
            local cart_json = json.encode(cart)
            ngx.header["Set-Cookie"] = "cart=" .. ngx.escape_uri(cart_json) ..
                "; Path=/; Max-Age=604800; SameSite=None; Secure=false"

            return { json = { message = "Removed from cart", cart = cart }, status = 200 }
        end
    }))

    -- Clear cart
    app:match("clear_cart", "/api/v2/cart/clear", respond_to({
        DELETE = function(_self)
            -- Clear cookie
            ngx.header["Set-Cookie"] = "cart=; Path=/; Max-Age=0; SameSite=None; Secure=false"

            return { json = { message = "Cart cleared" }, status = 200 }
        end
    }))

    -- Debug session endpoint
    app:match("debug_session", "/api/v2/cart/debug", respond_to({
        GET = function(_self)
            local session_lib = require("resty.session")
            local session, err = session_lib.start()

            local debug_info = {
                session_available = session ~= nil,
                session_error = err,
                cookie_cart = ngx.var.cookie_cart,
                headers = ngx.req.get_headers()
            }

            if session then
                debug_info.session_data = session:get("cart") or "no_cart_data"
            end

            return { json = debug_info, status = 200 }
        end
    }))
end