const express = require("express");
const multer = require("multer");
const fs = require("fs");
const path = require("path");
const { body, validationResult } = require("express-validator");
const { PutObjectCommand } = require("@aws-sdk/client-s3");
const s3 = require("../utils/s3Client");
const auth = require("../middleware/auth");

const router = express.Router();

// Multer config
const storage = multer.diskStorage({
  destination: (_, __, cb) => cb(null, "uploads/"),
  filename: (_, file, cb) => cb(null, Date.now() + "-" + file.originalname),
});
const upload = multer({
  storage,
  fileFilter: (_, file, cb) => {
    const allowed = ["image/jpeg", "image/png", "image/webp"];
    cb(null, allowed.includes(file.mimetype));
  },
  limits: { fileSize: 5 * 1024 * 1024 }, // 5MB max
});

router.post("/upload", auth, upload.single("image"), async (req, res, next) => {
  console.log("req.file:", req.file, "req.body:", req.body);

  if (!req.file)
    return res.status(400).json({ error: "Image file is required." });

  try {
    const fileStream = fs.createReadStream(req.file.path);

    const params = {
      Bucket: process.env.MINIO_BUCKET,
      Key: req.file.filename,
      Body: fileStream,
      ContentType: req.file.mimetype,
    };

    await s3.send(new PutObjectCommand(params));
    fs.unlinkSync(req.file.path);

    const minioEndpoint =
      process.env.MINIO_ENDPOINT || "https://your-minio-server:9000";
    const bucketName = process.env.MINIO_BUCKET;
    const fileUrl = `${minioEndpoint}/${bucketName}/${req.file.filename}`;

    res.json({
      message: "Upload successful",
      file: req.file.filename,
      url: fileUrl,
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
