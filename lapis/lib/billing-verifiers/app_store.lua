-- App Store receipt verification: not built yet (docs/BILLING_ENTITLEMENTS.md §12).
-- Verify on your own server, then record it: POST /api/v2/entitlements/:app/purchases.
return {
    verify = function()
        return nil, { status = 501, code = "not_implemented",
            message = "App Store verification isn't built yet: verify the receipt on your server and record "
                .. "the purchase with POST /api/v2/entitlements/:app/purchases" }
    end,
}
