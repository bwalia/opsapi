module.exports = {
  apps: [
    {
      name: "opsapi-dashboard",
      script: "server.js",

      // Clustering: Use 2 instances for better concurrency
      // This allows handling more concurrent requests without blocking
      instances: 2,
      exec_mode: "cluster",

      // Auto-restart configuration
      autorestart: true,
      watch: false,
      max_memory_restart: "500M",

      // Restart delay to prevent rapid restart loops
      restart_delay: 1000,

      // Kill timeout - give process time to cleanup
      kill_timeout: 5000,

      // Wait for ready signal before considering app launched
      wait_ready: true,
      listen_timeout: 10000,

      // Environment variables
      env: {
        NODE_ENV: "production",
        PORT: 8039,
        HOSTNAME: "0.0.0.0",
      },

      // Graceful shutdown
      shutdown_with_message: true,

      // Error handling - don't exit on error, just restart
      exp_backoff_restart_delay: 100,

      // Logging
      combine_logs: true,
      merge_logs: true,
    },
  ],
};
