# Runs the main business rules against a FRESH database (docker compose up -d). Needs curl + python3.
# Usage: bash scripts/api_smoke_test.sh
B=localhost:8080/api
j(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
post(){ curl -s -X POST -H 'Content-Type: application/json' ${3:+-H "Authorization: Bearer $3"} -d "${2:-{\}}" $B$1; }
get(){ curl -s ${2:+-H "Authorization: Bearer $2"} $B$1; }
IT=$(post /auth/login '{"username":"it.staff","password":"staff123"}' | j "d['token']")
AD=$(post /auth/login '{"username":"admin","password":"admin123"}' | j "d['token']")
echo "bad login:"; post /auth/login '{"username":"it.staff","password":"x"}'; echo
for n in Asha Bob Cara Dev; do post /tokens "{\"department_id\":1,\"visitor_name\":\"$n\"}" | j "(d['token_number'],d['position'],d['estimated_wait_minutes'])"; done
echo "-- call next (A serves)"; post /admin/departments/1/call-next "" $IT | j "(d['token_number'],d['status'])"
echo "-- 2nd call-next must 409"; post /admin/departments/1/call-next "" $IT
echo; echo "-- make IT-003 priority (id 3)"; post /admin/tokens/3/priority '{"priority":true}' $IT | j "(d['token_number'],d['position'],d['is_priority'])"
echo "-- IT-002 position now:"; get /tokens/2 | j "(d['position'],d['people_ahead'])"
echo "-- complete IT-001"; post /admin/tokens/1/complete "" $IT | j "d['status']"
echo "-- call next -> expect IT-003 (priority)"; post /admin/departments/1/call-next "" $IT | j "d['token_number']"
echo "-- no-show #1 on IT-003 -> waiting at end"; post /admin/tokens/3/no-show "" $IT | j "(d['status'],d['position'],d['no_show_count'])"
echo "-- call next -> IT-003 again(priority tier) then no-show #2"; post /admin/departments/1/call-next "" $IT | j "d['token_number']"; post /admin/tokens/3/no-show "" $IT | j "(d['status'],d['cancel_reason'])"
echo "-- cancel IT-004 by visitor"; post /tokens/4/cancel | j "(d['status'],d['cancel_reason'])"
echo "-- cancel again -> 409"; post /tokens/4/cancel
echo; echo "-- pause HR (id 2) then create -> 409"; post /admin/departments/2/pause '{"paused":true}' $AD; echo; post /tokens '{"department_id":2,"visitor_name":"Eve"}'
echo; echo "-- IT staff pausing HR -> 403"; post /admin/departments/2/pause '{"paused":false}' $IT
echo; echo "-- resume HR, create HR token (HR-002? no HR-001)"; post /admin/departments/2/pause '{"paused":false}' $AD >/dev/null; post /tokens '{"department_id":2,"visitor_name":"Eve"}' | j "(d['id'],d['token_number'])"
echo "-- transfer IT-002 (id 2) to ACC (3)"; post /admin/tokens/2/transfer '{"department_id":3}' $IT | j "(d['token_number'],d['transferred_from'],d['department_code'],d['position'])"
echo "-- dashboard (admin)"; get /admin/dashboard $AD | j "(d['totals'],[ (x['code'],x['waiting'],x['completed'],x['no_shows']) for x in d['departments']])"
echo "-- departments"; get /departments | j "[(x['code'],x['waiting'],x['is_paused']) for x in d]"
