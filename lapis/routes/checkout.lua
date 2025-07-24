local respond_to = require("lapis.application").respond_to
local OrderQueries = require("queries.OrderQueries")
local OrderitemQueries = require("queries.OrderitemQueries")
local CustomerQueries = require("queries.CustomerQueries")
local AuthMiddleware = require("middleware.auth")

return function(app)
    app:match("checkout", "/api/v2/checkout", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local params = self.params
            local session = require("resty.session").start()
            local cart = session:get("cart") or {}
            
            if not next(cart) then
                return { json = { error = "Cart is empty" }, status = 400 }
            end
            
            if not params.billing_address or not params.billing_address.name then
                return { json = { error = "Billing address required" }, status = 400 }
            end
            
            local success, result = pcall(function()
                local customer
                if params.customer_email then
                    customer = CustomerQueries.create({
                        email = params.customer_email,
                        first_name = params.customer_first_name,
                        last_name = params.customer_last_name,
                        phone = params.customer_phone
                    })
                end
                
                local subtotal = 0
                local store_orders = {}
                
                for product_uuid, item in pairs(cart) do
                    local StoreproductQueries = require("queries.StoreproductQueries")
                    local product = StoreproductQueries.show(product_uuid)
                    if not product then
                        error("Product not found: " .. product_uuid)
                    end
                    
                    local store_id = product.store_id
                    if not store_orders[store_id] then
                        store_orders[store_id] = { items = {}, subtotal = 0 }
                    end
                    
                    local item_total = product.price * item.quantity
                    table.insert(store_orders[store_id].items, {
                        product = product,
                        quantity = item.quantity,
                        price = product.price,
                        total = item_total
                    })
                    
                    store_orders[store_id].subtotal = store_orders[store_id].subtotal + item_total
                    subtotal = subtotal + item_total
                end
                
                local tax_amount = params.tax_amount or (subtotal * 0.1)
                local total_amount = subtotal + tax_amount
                
                local orders = {}
                for store_id, store_order in pairs(store_orders) do
                    local order = OrderQueries.create({
                        store_id = store_id,
                        customer_id = customer and customer.id or nil,
                        subtotal = store_order.subtotal,
                        tax_amount = tax_amount * (store_order.subtotal / subtotal),
                        total_amount = store_order.subtotal + (tax_amount * (store_order.subtotal / subtotal)),
                        billing_address = params.billing_address,
                        shipping_address = params.shipping_address or params.billing_address
                    })
                    
                    for _, item in ipairs(store_order.items) do
                        OrderitemQueries.create({
                            order_id = order.id,
                            product_id = item.product.id,
                            quantity = item.quantity,
                            price = item.price,
                            total = item.total,
                            product_title = item.product.name,
                            sku = item.product.sku
                        })
                    end
                    
                    table.insert(orders, order)
                end
                
                session:set("cart", {})
                session:save()
                
                return { orders = orders, total_amount = total_amount, message = "Checkout successful" }
            end)
            
            if not success then
                return { json = { error = result }, status = 400 }
            end
            
            return { json = result, status = 201 }
        end)
    }))
end