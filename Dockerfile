# syntax=docker/dockerfile:1

########################################
# Minimal OpenClaw Build (Optimized)
########################################
FROM node:22-bookworm-slim

# Basic setup
ENV NODE_ENV=production \
    OPENCLAW_NO_ONBOARD=1

# Install only essential tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Set working dir
WORKDIR /app

# Install OpenClaw globally
# RUN npm install -g openclaw
RUN npm install -g openclaw --production --no-audit --no-fund

# Copy project files
COPY . .

# Make scripts executable
RUN chmod +x /app/scripts/*.sh

# Memory optimization
ENV NODE_OPTIONS="--max-old-space-size=1024"

# Expose port
EXPOSE 18789

# Start app
CMD ["bash", "/app/scripts/bootstrap.sh"]
