--[[
    Delivery Partner Verification System

    Professional verification workflow with:
    - Document upload and submission
    - Verification status tracking
    - Admin verification endpoints
    - Self-service verification requests
    - Verification history

    Author: Senior Backend Engineer
    Date: 2025-01-19
]]--

local respond_to = require("lapis.application").respond_to
local AuthMiddleware = require("middleware.auth")
local db = require("lapis.db")
local cjson = require("cjson")
local Global = require("helper.global")

return function(app)
    --[[
        Get Verification Status

        Returns detailed verification status including:
        - Current verification state
        - Required documents
        - Missing documents
        - Verification timeline
        - Next steps
    ]]--
    app:match("get_verification_status", "/api/v2/delivery-partners/verification/status", respond_to({
        GET = AuthMiddleware.requireAuth(function(self)
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query([[
                SELECT
                    id, uuid, company_name, is_verified, is_active,
                    verification_documents, created_at
                FROM delivery_partners
                WHERE user_id = ?
            ]], user.id)[1]

            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Parse verification documents
            local documents = {}
            if delivery_partner.verification_documents then
                local ok, parsed = pcall(cjson.decode, delivery_partner.verification_documents)
                if ok then
                    documents = parsed
                end
            end

            -- Define required documents
            local required_documents = {
                {
                    id = "driving_license",
                    name = "Driving License",
                    description = "Valid driving license with photo",
                    required = true
                },
                {
                    id = "vehicle_registration",
                    name = "Vehicle Registration",
                    description = "Vehicle registration certificate (RC)",
                    required = true
                },
                {
                    id = "identity_proof",
                    name = "Identity Proof",
                    description = "Aadhaar Card, PAN Card, or Passport",
                    required = true
                },
                {
                    id = "address_proof",
                    name = "Address Proof",
                    description = "Utility bill or rental agreement (within 3 months)",
                    required = true
                },
                {
                    id = "profile_photo",
                    name = "Profile Photo",
                    description = "Clear passport-size photograph",
                    required = true
                },
                {
                    id = "bank_details",
                    name = "Bank Account Details",
                    description = "Cancelled cheque or bank passbook",
                    required = false
                }
            }

            -- Check which documents are submitted
            local submitted_docs = {}
            local missing_docs = {}

            for _, req_doc in ipairs(required_documents) do
                local found = false
                for _, submitted in ipairs(documents) do
                    if submitted.type == req_doc.id then
                        found = true
                        table.insert(submitted_docs, {
                            type = req_doc.id,
                            name = req_doc.name,
                            url = submitted.url,
                            uploaded_at = submitted.uploaded_at,
                            status = submitted.status or "pending"
                        })
                        break
                    end
                end

                if not found and req_doc.required then
                    table.insert(missing_docs, req_doc)
                end
            end

            -- Determine verification status
            local verification_status = "pending"
            local can_submit = #missing_docs == 0
            local next_step = ""

            if delivery_partner.is_verified then
                verification_status = "verified"
                next_step = "You are verified and can accept orders"
            elseif not can_submit then
                verification_status = "incomplete"
                next_step = "Upload all required documents to submit for verification"
            elseif #submitted_docs > 0 and #missing_docs == 0 then
                verification_status = "under_review"
                next_step = "Your documents are under review. We'll notify you once verified."
            else
                verification_status = "not_started"
                next_step = "Start by uploading your documents"
            end

            return {
                json = {
                    partner_id = delivery_partner.uuid,
                    company_name = delivery_partner.company_name,
                    verification = {
                        status = verification_status,
                        is_verified = delivery_partner.is_verified,
                        is_active = delivery_partner.is_active,
                        can_submit_for_review = can_submit,
                        next_step = next_step,
                        registered_at = delivery_partner.created_at
                    },
                    documents = {
                        required = required_documents,
                        submitted = submitted_docs,
                        missing = missing_docs,
                        total_required = #required_documents,
                        total_submitted = #submitted_docs,
                        total_missing = #missing_docs,
                        completion_percentage = #required_documents > 0
                            and math.floor((#submitted_docs / #required_documents) * 100)
                            or 0
                    }
                }
            }
        end)
    }))

    --[[
        Upload Verification Document

        Allows partners to upload verification documents.
        Documents are stored as JSON in the verification_documents field.

        Frontend should handle actual file upload to storage (S3, Cloudinary, etc.)
        and send the URL to this endpoint.
    ]]--
    app:match("upload_verification_document", "/api/v2/delivery-partners/verification/documents", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local params = self.params

            if not params.document_type or not params.document_url then
                return {
                    status = 400,
                    json = {
                        error = "document_type and document_url are required",
                        example = {
                            document_type = "driving_license",
                            document_url = "https://cdn.example.com/docs/license.jpg"
                        }
                    }
                }
            end

            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query([[
                SELECT id, verification_documents FROM delivery_partners WHERE user_id = ?
            ]], user.id)[1]

            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Parse existing documents
            local documents = {}
            if delivery_partner.verification_documents then
                local ok, parsed = pcall(cjson.decode, delivery_partner.verification_documents)
                if ok then
                    documents = parsed
                end
            end

            -- Check if document type already exists (update it)
            local doc_updated = false
            for i, doc in ipairs(documents) do
                if doc.type == params.document_type then
                    documents[i] = {
                        type = params.document_type,
                        url = params.document_url,
                        uploaded_at = db.format_date(),
                        status = "pending"
                    }
                    doc_updated = true
                    break
                end
            end

            -- If not found, add new document
            if not doc_updated then
                table.insert(documents, {
                    type = params.document_type,
                    url = params.document_url,
                    uploaded_at = db.format_date(),
                    status = "pending"
                })
            end

            -- Update database
            db.update("delivery_partners", {
                verification_documents = cjson.encode(documents),
                updated_at = db.format_date()
            }, "id = ?", delivery_partner.id)

            return {
                json = {
                    message = "Document uploaded successfully",
                    document = {
                        type = params.document_type,
                        url = params.document_url,
                        status = "pending"
                    },
                    total_documents = #documents
                },
                status = 201
            }
        end)
    }))

    --[[
        Submit for Verification

        Once all required documents are uploaded, partner can submit for admin review.
        This doesn't verify the partner, it just marks them as ready for review.
    ]]--
    app:match("submit_for_verification", "/api/v2/delivery-partners/verification/submit", respond_to({
        POST = AuthMiddleware.requireAuth(function(self)
            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query([[
                SELECT id, verification_documents, is_verified FROM delivery_partners WHERE user_id = ?
            ]], user.id)[1]

            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            if delivery_partner.is_verified then
                return {
                    status = 400,
                    json = { error = "You are already verified" }
                }
            end

            -- Parse documents
            local documents = {}
            if delivery_partner.verification_documents then
                local ok, parsed = pcall(cjson.decode, delivery_partner.verification_documents)
                if ok then
                    documents = parsed
                end
            end

            -- Check required documents
            local required_types = {"driving_license", "vehicle_registration", "identity_proof", "address_proof", "profile_photo"}
            local submitted_types = {}

            for _, doc in ipairs(documents) do
                submitted_types[doc.type] = true
            end

            local missing = {}
            for _, req_type in ipairs(required_types) do
                if not submitted_types[req_type] then
                    table.insert(missing, req_type)
                end
            end

            if #missing > 0 then
                return {
                    status = 400,
                    json = {
                        error = "Missing required documents",
                        missing_documents = missing,
                        message = "Please upload all required documents before submitting"
                    }
                }
            end

            -- Mark all documents as submitted for review
            for i, doc in ipairs(documents) do
                documents[i].status = "under_review"
                documents[i].submitted_at = db.format_date()
            end

            -- Update database
            db.update("delivery_partners", {
                verification_documents = cjson.encode(documents),
                updated_at = db.format_date()
            }, "id = ?", delivery_partner.id)

            -- TODO: Send notification to admin
            -- TODO: Send email to partner confirming submission

            return {
                json = {
                    message = "Documents submitted for verification successfully",
                    status = "under_review",
                    next_step = "Our team will review your documents within 24-48 hours. You'll receive an email once verified."
                }
            }
        end)
    }))

    --[[
        Admin: Get Pending Verifications

        Returns list of delivery partners pending verification.
        Only accessible by admin users.
    ]]--
    app:match("admin_get_pending_verifications", "/api/v2/admin/delivery-partners/pending-verification", respond_to({
        GET = AuthMiddleware.requireRole("administrative", function(self)
            local partners = db.query([[
                SELECT
                    dp.id,
                    dp.uuid,
                    dp.company_name,
                    dp.contact_person_name,
                    dp.contact_person_phone,
                    dp.contact_person_email,
                    dp.city,
                    dp.state,
                    dp.verification_documents,
                    dp.created_at,
                    u.email as user_email,
                    u.first_name,
                    u.last_name
                FROM delivery_partners dp
                INNER JOIN users u ON dp.user_id = u.id
                WHERE dp.is_verified = FALSE
                AND dp.verification_documents IS NOT NULL
                AND dp.verification_documents != '[]'
                ORDER BY dp.created_at DESC
                LIMIT 100
            ]])

            -- Parse documents for each partner
            for _, partner in ipairs(partners) do
                if partner.verification_documents then
                    local ok, parsed = pcall(cjson.decode, partner.verification_documents)
                    if ok then
                        partner.verification_documents = parsed
                    end
                end
            end

            return {
                json = {
                    partners = partners,
                    count = #partners
                }
            }
        end)
    }))

    --[[
        Admin: Verify Delivery Partner

        Admin endpoint to approve or reject a delivery partner's verification.
    ]]--
    app:match("admin_verify_partner", "/api/v2/admin/delivery-partners/:uuid/verify", respond_to({
        POST = AuthMiddleware.requireRole("administrative", function(self)
            local partner_uuid = self.params.uuid
            local params = self.params

            if not params.action or (params.action ~= "approve" and params.action ~= "reject") then
                return {
                    status = 400,
                    json = {
                        error = "action must be 'approve' or 'reject'",
                        example = {
                            action = "approve",
                            notes = "All documents verified"
                        }
                    }
                }
            end

            local delivery_partner = db.query([[
                SELECT
                    dp.*,
                    u.id as user_id,
                    u.email as user_email
                FROM delivery_partners dp
                INNER JOIN users u ON dp.user_id = u.id
                WHERE dp.uuid = ?
            ]], partner_uuid)[1]

            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner not found" } }
            end

            if params.action == "approve" then
                -- Approve verification
                db.update("delivery_partners", {
                    is_verified = true,
                    is_active = true,
                    updated_at = db.format_date()
                }, "uuid = ?", partner_uuid)

                -- Update document status
                local documents = {}
                if delivery_partner.verification_documents then
                    local ok, parsed = pcall(cjson.decode, delivery_partner.verification_documents)
                    if ok then
                        documents = parsed
                        for i, doc in ipairs(documents) do
                            documents[i].status = "approved"
                            documents[i].approved_at = db.format_date()
                        end

                        db.update("delivery_partners", {
                            verification_documents = cjson.encode(documents)
                        }, "uuid = ?", partner_uuid)
                    end
                end

                -- TODO: Send approval email to partner
                -- TODO: Send welcome email with next steps

                return {
                    json = {
                        message = "Delivery partner verified successfully",
                        partner_id = partner_uuid,
                        status = "verified",
                        notes = params.notes
                    }
                }

            else
                -- Reject verification
                local rejection_reason = params.rejection_reason or "Documents did not meet verification criteria"

                -- Update document status
                local documents = {}
                if delivery_partner.verification_documents then
                    local ok, parsed = pcall(cjson.decode, delivery_partner.verification_documents)
                    if ok then
                        documents = parsed
                        for i, doc in ipairs(documents) do
                            documents[i].status = "rejected"
                            documents[i].rejected_at = db.format_date()
                            documents[i].rejection_reason = rejection_reason
                        end

                        db.update("delivery_partners", {
                            verification_documents = cjson.encode(documents),
                            updated_at = db.format_date()
                        }, "uuid = ?", partner_uuid)
                    end
                end

                -- TODO: Send rejection email with reason
                -- TODO: Allow partner to re-submit

                return {
                    json = {
                        message = "Verification rejected",
                        partner_id = partner_uuid,
                        status = "rejected",
                        rejection_reason = rejection_reason,
                        notes = params.notes
                    }
                }
            end
        end)
    }))

    --[[
        Delete Verification Document

        Allows partner to remove an uploaded document before submission.
    ]]--
    app:match("delete_verification_document", "/api/v2/delivery-partners/verification/documents/:document_type", respond_to({
        DELETE = AuthMiddleware.requireAuth(function(self)
            local document_type = self.params.document_type

            local user = db.query("SELECT id FROM users WHERE uuid = ?", self.current_user.uuid)[1]
            if not user then
                return { status = 404, json = { error = "User not found" } }
            end

            local delivery_partner = db.query([[
                SELECT id, verification_documents FROM delivery_partners WHERE user_id = ?
            ]], user.id)[1]

            if not delivery_partner then
                return { status = 404, json = { error = "Delivery partner profile not found" } }
            end

            -- Parse documents
            local documents = {}
            if delivery_partner.verification_documents then
                local ok, parsed = pcall(cjson.decode, delivery_partner.verification_documents)
                if ok then
                    documents = parsed
                end
            end

            -- Remove document
            local new_documents = {}
            local found = false
            for _, doc in ipairs(documents) do
                if doc.type ~= document_type then
                    table.insert(new_documents, doc)
                else
                    found = true
                end
            end

            if not found then
                return {
                    status = 404,
                    json = { error = "Document not found" }
                }
            end

            -- Update database
            db.update("delivery_partners", {
                verification_documents = cjson.encode(new_documents),
                updated_at = db.format_date()
            }, "id = ?", delivery_partner.id)

            return {
                json = {
                    message = "Document deleted successfully",
                    document_type = document_type,
                    remaining_documents = #new_documents
                }
            }
        end)
    }))
end
