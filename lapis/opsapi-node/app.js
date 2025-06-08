require("dotenv").config();
const express = require("express");
const uploadRoute = require("./routes/upload");
const errorHandler = require("./middleware/errorHandler");

const app = express();
app.use(express.json());

app.use("/api", uploadRoute);

// Error middleware
app.use(errorHandler);

app.listen(process.env.PORT, () => {
  console.log(`Server running on http://localhost:${process.env.PORT}`);
});
