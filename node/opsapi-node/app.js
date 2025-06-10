require("dotenv").config();
const express = require("express");
const uploadRoute = require("./routes/upload");
const errorHandler = require("./middleware/errorHandler");

const port = process.env.PORT || 3000; // Use environment variable or default

const app = express();
app.use(express.json());

app.get("/", (req, res) => {
  res.send(
    "Welcome to opsapi-node! This is the Node.js microservice used by the Lua Lapis app."
  );
});
app.use("/api", uploadRoute);

// Error middleware
app.use(errorHandler);

app.listen(port, () => {
  console.log(`Server running on http://localhost:${process.env.PORT}`);
});
