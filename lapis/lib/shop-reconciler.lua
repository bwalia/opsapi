--[[
    Shop payment reconciler timer
    =============================
    Started from nginx.conf init_worker_by_lua. Runs only when the "shop"
    feature is enabled, only on worker 0, every SHOP_RECONCILE_SECONDS (300).
    The admin endpoint POST /api/v2/shop/admin/reconcile calls the same
    ShopStripeQueries.reconcile().
]]

local ShopReconciler = {}

local INTERVAL = 300

function ShopReconciler.start()
    if ngx.worker.id() ~= 0 then return end
    local ok_cfg, ProjectConfig = pcall(require, "helper.project-config")
    if not ok_cfg or not ProjectConfig.isFeatureEnabled("shop") then return end
    local ok, err = ngx.timer.every(INTERVAL, function(premature)
        local ok_q, Q = pcall(require, "queries.ShopStripeQueries")
        if not ok_q then
            ngx.log(ngx.ERR, "[shop-reconcile] load failed: ", tostring(Q))
            return
        end
        Q.timerTick(premature)
    end)
    if not ok then ngx.log(ngx.ERR, "[shop-reconcile] timer not started: ", tostring(err)) end
end

return ShopReconciler
