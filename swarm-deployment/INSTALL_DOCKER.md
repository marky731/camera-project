# Docker Installation Guide for CloudCam Test Server

## Quick Installation

Run these commands to install Docker on Ubuntu:

```bash
# Update package list
sudo apt-get update

# Install Docker
sudo apt-get install -y docker.io docker-compose

# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to docker group (to run docker without sudo)
sudo usermod -aG docker $USER

# Verify installation
docker --version
```

**Important:** After adding yourself to the docker group, you need to **log out and log back in** for the group membership to take effect.

## Alternative Installation (Docker CE)

If you prefer the latest Docker CE:

```bash
# Install prerequisites
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker repository
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker CE
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Start Docker
sudo systemctl start docker
sudo systemctl enable docker

# Add user to docker group
sudo usermod -aG docker $USER
```

## Verification

After installation and re-login, test Docker:

```bash
# Test Docker
docker run hello-world

# Test Docker Compose
docker compose version

# Check Docker info
docker info
```

## Next Steps

Once Docker is installed and working:

1. Navigate to the swarm deployment directory:
   ```bash
   cd /home/nbadmin/camera-project/swarm-deployment
   ```

2. Run the test deployment script:
   ```bash
   ./deploy-single-node-test.sh
   ```

This will automatically:
- Initialize Docker Swarm
- Build required images
- Deploy all services
- Set up SSL certificates
- Configure nginx reverse proxy

## Troubleshooting

### Permission Issues
If you get permission denied errors:
```bash
sudo chown $USER:$USER /var/run/docker.sock
```

### Docker not starting
```bash
sudo systemctl status docker
sudo systemctl start docker
```

### Group membership not working
Log out completely and log back in, or run:
```bash
newgrp docker
```