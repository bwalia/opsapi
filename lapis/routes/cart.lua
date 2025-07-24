local respond_to = require("lapis.application").respond_to
local StoreproductQueries = require("queries.StoreproductQueries")
local AuthMiddleware = require("middleware.auth")

return function(app)
    -- Add to cart (session-based)
    app:match("add_to_cart", "/api/v2/cart/add", respond_to({
        POST = function(self)
            local product_uuid = self.params.product_uuid
            local quantity = tonumber(self.params.quantity) or 1
            
            if not product_uuid then
                return { json = { error = "Product UUID required" }, status = 400 }
            end
            
            -- Check inventory
            local available, err = StoreproductQueries.checkInventory(product_uuid, quantity)
            if not available then
                return { json = { error = err }, status = 400 }
            end
            
            -- Get or create session cart
            local session_lib = require("resty.session")
            local session = session_lib.start()
            if not session then
                -- Fallback: try to open/create a new session
                session = session_lib.new()
                if not session then
                    return { json = { error = "Session initialization failed" }, status = 500 }
                end
            end
            
            local cart = session:get("cart")
            if type(cart) ~= "table" then
                cart = {}
            end
            
            -- Add/update item in cart
            if cart[product_uuid] then
                cart[product_uuid].quantity = cart[product_uuid].quantity + quantity
            else
                local product = StoreproductQueries.show(product_uuid)
                if not product then
                    return { json = { error = "Product not found" }, status = 404 }
                end
                
                cart[product_uuid] = {
                    product_uuid = product_uuid,
                    name = product.name,
                    price = product.price,
                    quantity = quantity
                }
            end
            
            session:set("cart", cart)
            session:save()
            
            return { json = { message = "Added to cart", cart = cart }, status = 200 }
        end
    }))
    
    -- Get cart
    app:match("get_cart", "/api/v2/cart", respond_to({
        GET = function(self)
            local session_lib = require("resty.session")
            local session = session_lib.start()
            local cart = {}
            
            if session then
                cart = session:get("cart")
                if type(cart) ~= "table" then
                    cart = {}
                end
            end
            
            local total = 0
            local items = {}
            for uuid, item in pairs(cart) do
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
            local session_lib = require("resty.session")
            local session = session_lib.start()
            
            if session then
                local cart = session:get("cart") or {}
                cart[product_uuid] = nil
                session:set("cart", cart)
                session:save()
                return { json = { message = "Removed from cart", cart = cart }, status = 200 }
            else
                return { json = { message = "Removed from cart", cart = {} }, status = 200 }
            end
        end
    }))
    
    -- Clear cart
    app:match("clear_cart", "/api/v2/cart/clear", respond_to({
        DELETE = function(self)
            local session_lib = require("resty.session")
            local session = session_lib.start()
            
            if session then
                session:set("cart", {})
                session:save()
            end
            
            return { json = { message = "Cart cleared" }, status = 200 }
        end
    }))
end