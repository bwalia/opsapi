# 📊 Grafana Dashboard - HTTP Status Byte Transfer Guide

## New Panels Added ✅

Your Grafana dashboard now includes **2 new panels** to monitor HTTP response bytes by status code:

### 1. 📦 Total Bytes Transferred by HTTP Status
**Location**: Row 2, Left Panel  
**Type**: Time Series Graph  
**Metric**: `sum by (status) (nginx_http_response_size_bytes_sum)`

**What it shows:**
- Cumulative total bytes sent for each HTTP status code (200, 401, 404, 500, etc.)
- Shows trends over time
- Uses byte formatting (KB, MB, GB)
- Legend shows LAST and MAX values

**Use Cases:**
- Track total data transfer per status code
- Identify which status codes are sending the most data
- Monitor if error responses are consuming significant bandwidth
- Detect anomalies in data transfer patterns

---

### 2. 📊 Response Size Rate by Status (Bytes/sec)
**Location**: Row 2, Right Panel  
**Type**: Stacked Time Series Graph  
**Metric**: `sum by (status, method) (rate(nginx_http_response_size_bytes_sum[5m]))`

**What it shows:**
- Rate of bytes transferred per second
- Broken down by HTTP method (GET, POST, etc.) and status code
- Stacked visualization shows contribution of each method+status
- Legend shows MEAN and MAX values

**Use Cases:**
- Monitor bandwidth usage in real-time (bytes per second)
- Compare bandwidth usage across different HTTP methods
- Identify which operations consume the most bandwidth
- Track bandwidth spikes and patterns

---

## 📈 How to Use in Grafana

### Access the Dashboard

1. **Open Grafana**: http://localhost:3000
2. **Login**: 
   - Username: `admin`
   - Password: `admin`
3. **Navigate**: 
   - Click **Dashboards** (left menu)
   - Select **OpsAPI - Complete Monitoring Dashboard**

### View the Panels

The new panels are in **Row 2** (second row from top):
- **Left side**: Total Bytes by Status (cumulative)
- **Right side**: Bytes Rate by Status (per second)

### Interact with the Panels

**Zoom In/Out:**
- Click and drag on the graph to zoom into a time range
- Double-click to reset zoom

**Time Range:**
- Use the time picker (top right) to change the displayed time window
- Default: Last 1 hour
- Options: 5m, 15m, 30m, 1h, 3h, 6h, 12h, 24h, 7d, 30d

**Legend Interaction:**
- Click on a legend item to hide/show that series
- Hover over legend values to see calculations (last, max, mean)

**Tooltip:**
- Hover over the graph to see exact values at that timestamp
- Shows all series at that point in time

---

## 🔍 Sample Queries

### Query 1: Total Bytes by Status
```promql
sum by (status) (nginx_http_response_size_bytes_sum)
```
**Result:** Cumulative bytes sent per HTTP status code

### Query 2: Bytes Rate by Status and Method
```promql
sum by (status, method) (rate(nginx_http_response_size_bytes_sum[5m]))
```
**Result:** Bytes per second, broken down by status and method

### Query 3: Top 5 Status Codes by Bandwidth
```promql
topk(5, sum by (status) (rate(nginx_http_response_size_bytes_sum[5m])))
```
**Result:** Top 5 status codes consuming the most bandwidth

### Query 4: Percentage of 200 OK Responses
```promql
sum(rate(nginx_http_response_size_bytes_sum{status="200"}[5m])) / 
sum(rate(nginx_http_response_size_bytes_sum[5m])) * 100
```
**Result:** Percentage of bandwidth used by successful responses

### Query 5: Error Response Bandwidth (4xx + 5xx)
```promql
sum(rate(nginx_http_response_size_bytes_sum{status=~"4..|5.."}[5m]))
```
**Result:** Bytes per second for all error responses

---

## 💡 Insights You Can Gain

### 1. **Successful vs Error Traffic**
- Compare bytes sent for HTTP 200 vs 4xx/5xx
- Identify if errors are consuming excessive bandwidth

### 2. **Method-Based Analysis**
- See which HTTP methods (GET, POST, PUT, DELETE) transfer the most data
- Identify if certain methods are disproportionately heavy

### 3. **Bandwidth Optimization Opportunities**
- Spot endpoints returning large payloads
- Identify candidates for compression or pagination
- Find inefficient API calls

### 4. **Security Monitoring**
- Monitor bandwidth for 401 (Unauthorized) responses
- Track if authentication failures are causing bandwidth issues
- Detect potential data exfiltration attempts

### 5. **Performance Correlation**
- Cross-reference with latency panels
- See if high bandwidth correlates with slow response times
- Identify bottlenecks

---

## 🎯 Real-World Examples

### Example 1: Identifying Large Error Responses
**Observation**: HTTP 500 status shows unexpectedly high bytes  
**Action**: Investigate error responses that might be returning full stack traces  
**Fix**: Implement proper error handling to return concise error messages

### Example 2: GET vs POST Bandwidth
**Observation**: GET requests show 10x more bandwidth than POST  
**Action**: Review GET endpoints returning large datasets  
**Fix**: Implement pagination, filtering, or compression

### Example 3: Bandwidth Spike Detection
**Observation**: Sudden spike in bytes for HTTP 200 at specific time  
**Action**: Correlate with request logs to find the endpoint  
**Fix**: Optimize response size or add caching

### Example 4: Failed Authentication Impact
**Observation**: HTTP 401 showing significant bandwidth  
**Action**: Check if error responses are too verbose  
**Fix**: Return minimal error information

---

## 🔧 Customization Options

### Change Time Window
Edit the panel → Query Options → Min interval

### Add Alerts
1. Click the panel title → **Edit**
2. Go to **Alert** tab
3. Set conditions (e.g., bytes > threshold)
4. Configure notifications

### Modify Visualization
- **Graph Type**: Line, Bar, Stacked Area
- **Colors**: Customize per series
- **Units**: Change from bytes to bits, KB, MB
- **Legend**: Show/hide, change position

### Create Variations

**Variation 1: Only Error Responses**
```promql
sum by (status) (rate(nginx_http_response_size_bytes_sum{status=~"4..|5.."}[5m]))
```

**Variation 2: By Host**
```promql
sum by (host, status) (rate(nginx_http_response_size_bytes_sum[5m]))
```

**Variation 3: By Endpoint**
```promql
sum by (endpoint, status) (rate(nginx_http_response_size_bytes_sum[5m]))
```

---

## 🚀 Quick Actions

### Generate Test Data
```bash
# Generate traffic to see metrics populate
for i in {1..100}; do 
  curl -s http://localhost:4010/ > /dev/null
  curl -s http://localhost:4010/api/v2/products > /dev/null
done
```

### Check Raw Metrics
```bash
# View current byte counts
curl -s http://localhost:4010/metrics | grep "nginx_http_response_size_bytes_sum"
```

### Query Prometheus Directly
```bash
# Test the query
curl -s 'http://localhost:9090/api/v1/query?query=sum%20by%20(status)%20(nginx_http_response_size_bytes_sum)' | python3 -m json.tool
```

### Export Dashboard
1. Go to Dashboard settings (gear icon)
2. Click **JSON Model**
3. Copy the JSON
4. Save to file for backup

---

## 📊 Panel Configuration Details

### Panel 1: Total Bytes by Status
- **Display**: Time series with smooth lines
- **Fill**: 20% opacity with gradient
- **Line Width**: 2px
- **Points**: Hidden
- **Y-Axis**: Bytes (auto-formatted: KB, MB, GB)
- **Legend**: Table format showing Last and Max values
- **Tooltip**: Multi-series, sorted descending

### Panel 2: Bytes Rate by Status
- **Display**: Stacked time series
- **Fill**: 30% opacity with gradient
- **Stacking**: Normal (stacked area)
- **Line Width**: 2px
- **Points**: Hidden
- **Y-Axis**: Bytes per second (Bps)
- **Legend**: Table format showing Mean and Max values
- **Tooltip**: Multi-series, sorted descending

---

## ✅ Success Checklist

- [ ] Dashboard loads without errors
- [ ] Both new panels visible in Row 2
- [ ] Panels show data (may need to generate traffic)
- [ ] Time range selector works
- [ ] Legend values update in real-time
- [ ] Tooltips show correct information
- [ ] Zoom in/out functionality works

---

## 🔗 Related Documentation

- **QUICKSTART_MONITORING.md** - Quick start guide
- **PROMETHEUS_GRAFANA_INTEGRATION_SUMMARY.md** - Complete monitoring overview
- **METRICS_GUIDE.md** - All available metrics
- **DDOS_MITIGATION_GUIDE.md** - Security monitoring

---

## 🆘 Troubleshooting

### Panel Shows "No Data"
**Solution:**
1. Check time range (set to last 5-15 minutes)
2. Generate traffic: `curl http://localhost:4010/`
3. Verify metrics: `curl http://localhost:4010/metrics | grep response_size`
4. Check Prometheus targets: http://localhost:9090/targets

### Panel Shows Error
**Solution:**
1. Verify Prometheus datasource is connected
2. Test query in Prometheus: http://localhost:9090/graph
3. Check Grafana logs: `docker logs opsapi-grafana`

### Values Look Wrong
**Solution:**
1. Check unit formatting (should be "bytes" and "Bps")
2. Verify the time range isn't too wide
3. Confirm data is being collected: Check /metrics endpoint

---

**Dashboard Ready!** 🎉  
Access it now: http://localhost:3000

Your new panels are actively monitoring HTTP response byte transfers!
