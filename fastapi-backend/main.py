from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import time

app = FastAPI(title="OpsAPI FastAPI Service")

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
def read_root():
    return {
        "service": "OpsAPI FastAPI",
        "status": "Running",
        "timestamp": time.time()
    }

@app.get("/health")
def health_check():
    return {"status": "healthy", "version": "1.0.0"}
