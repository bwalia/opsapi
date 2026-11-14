#!/bin/sh
# Put the landlord demo account back to "statements sorted, nothing filed" so the
# ending (record_ending.mjs) can be filmed again: the AI's unsure lines flagged
# again, NINO and HMRC connection removed. For the demo account on int only.
#   SP=<dir with landlord_email + int_pw> KUBECONFIG=... ./reset_ending.sh
set -eu
: "${SP:?set SP to the folder holding landlord_email and int_pw}"
A=${OPSAPI_API:-https://int-opsapi.workstation.co.uk}
NS=${K8S_NAMESPACE:-int}
E=$(cat "$SP/landlord_email")
TOK=$(curl -s -X POST "$A/auth/login" --data-urlencode "username=$E" --data-urlencode "password=$(cat "$SP/int_pw")" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s -o /dev/null -w 'disconnect HMRC %{http_code}\n' -X DELETE "$A/auth/hmrc/disconnect" \
  -H "Authorization: Bearer $TOK" -H "X-Namespace-Slug: workstation"
curl -s -o /dev/null -w 'remove NINO %{http_code}\n' -X DELETE "$A/api/v2/hmrc/nino" \
  -H "Authorization: Bearer $TOK" -H "X-Namespace-Slug: workstation"
P=$(kubectl -n "$NS" get pods -o name --field-selector=status.phase=Running | grep 'workstation-opsapi-' | grep -v -e dash -e hmrc | head -1)
kubectl -n "$NS" exec "$P" -c workstation-opsapi -- lapis exec "
local db=require('lapis.db') local u=db.query('SELECT id FROM users WHERE email=?','$E')[1]
local a=db.query([[UPDATE tax_transactions SET category='uncategorised_expense', hmrc_category='other_expenses',
  is_tax_deductible=false, classification_status='NEEDS_REVIEW', is_manually_reviewed=false, updated_at=NOW()
  WHERE user_id=? AND classified_by='fallback']], u.id)
local b=db.query([[UPDATE tax_transactions SET classification_status='NEEDS_REVIEW', updated_at=NOW()
  WHERE user_id=? AND category='equipment_purchase' AND description ILIKE '%KITCHEN%']], u.id)
local c=db.query([[UPDATE tax_transactions SET classification_status='CLASSIFIED', updated_at=NOW()
  WHERE user_id=? AND classification_status='CONFIRMED']], u.id)
print('reset rows', a.affected_rows, b.affected_rows, c.affected_rows)" 2>&1 | grep -v Defaulted
