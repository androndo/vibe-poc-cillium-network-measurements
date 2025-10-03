1. Check bootstrap-cillium.sh script
2. Ensure that cluster is created and cillium is installed
3. Deploy curl pod with GET request to https://httpbin.dev/range/1024
4. Get cillium metrics about network activity of this pod. How many bytes were sent and received.
5. Describe used query for metrics from 4.