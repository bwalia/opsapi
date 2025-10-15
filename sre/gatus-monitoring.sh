echo "
# Update your gatus/config/config.yml
endpoints:
  - name: "OpsAPI Kubernetes Health"
    group: "Kubernetes Services"
    url: "http://opsapi-svc.test.svc.cluster.local/health"
    interval: 30s
    conditions:
      - "[STATUS] == 200"
      - "[RESPONSE_TIME] < 1000"
      - "[BODY].status == healthy"
      - "len([BODY]) > 10"
  
  - name: "OpsAPI Kubernetes Metrics"
    group: "Kubernetes Services" 
    url: "http://opsapi-svc.test.svc.cluster.local/metrics"
    interval: 30s
    conditions:
      - "[STATUS] == 200"
      - "[RESPONSE_TIME] < 1000"
      - "[BODY] contains opsapi_up"
      - "[BODY] contains # HELP"
  
  - name: "OpsAPI Kubernetes OpenAPI"
    group: "Kubernetes Services"
    url: "http://opsapi-svc.test.svc.cluster.local/openapi.json"
    interval: 60s
    conditions:
      - "[STATUS] == 200"
      - "[RESPONSE_TIME] < 1000"
      - "[BODY].info.title == OpsAPI"
      - "len([BODY].paths) > 5"

  # Your existing endpoints...
  - name: "OpsAPI Lapis Health"
    group: "Dev Services"
    # ... rest of your config
" > lapis/gatus/config/config.yml"