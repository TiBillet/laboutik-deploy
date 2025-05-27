################################################
# Makefile pour LaBoutik - Système de Cashless TiBillet
################################################
#
# Ce Makefile permet l'installation et la configuration d'une instance LaBoutik
# sur un serveur VPS en production. Il automatise les tâches suivantes :
#
# - Installation des dépendances système (Docker, CrowdSec)
# - Configuration de l'espace swap (4GB) pour améliorer les performances
# - Vérification et installation de Python et des bibliothèques requises
# - Création des répertoires nécessaires
# - Configuration du fichier .env avec génération de clés sécurisées
# - Vérification de la connexion avec LesPass
# - Déploiement de l'application via Docker Compose
#
# Pour utiliser ce Makefile, exécutez simplement la commande 'make' suivie
# du nom de la cible souhaitée. Par exemple : 'make install-vps'
#
# Pour voir la liste complète des commandes disponibles : 'make help'
#
################################################

# Variables
SHELL := /bin/bash

# Couleurs pour les messages
GREEN := \033[0;32m
RED := \033[0;31m
YELLOW := \033[0;33m
NC := \033[0m # No Color

# Default target
.PHONY: help
help:
	@echo -e "\n${GREEN}📋 Available targets:${NC}"
	@echo -e "  ${GREEN}install${NC}       - 🚀 Set up a production VPS with required dependencies"
	@echo -e "  ${GREEN}install-docker${NC}    - 🐳 Install Docker"
	@echo -e "  ${GREEN}install-crowdsec${NC}  - 🛡️  Install CrowdSec"
	@echo -e "  ${GREEN}check-swap${NC}        - 💾 Check and configure swap space"
	@echo -e "  ${GREEN}check-python${NC}      - 🐍 Check Python installation and install required libraries"
	@echo -e "  ${GREEN}setup-dirs${NC}        - 📁 Create required directories"
	@echo -e "  ${GREEN}setup-env${NC}         - ⚙️  Create and configure .env file"
# 	@echo -e "  ${GREEN}setup${NC}             - 🔧 Complete setup (directories and .env)"
	@echo -e "  ${GREEN}verify-lespass${NC}    - 🔄 Verify connection with LesPass"
	@echo -e "  ${GREEN}check-traefik${NC}     - 🔍 Verify Traefik container is running"
# 	@echo -e "  ${GREEN}deploy${NC}            - 🚢 Deploy the application using Docker Compose"
# 	@echo -e "  ${GREEN}dev${NC}               - 💻 Start development environment"
# 	@echo -e "  ${GREEN}logs${NC}              - 📊 View logs from all services"
# 	@echo -e "  ${GREEN}backup${NC}            - 💾 Run backup"
# 	@echo -e "  ${GREEN}clean${NC}             - 🧹 Clean up Docker resources"

# VPS setup
.PHONY: install
install: update-upgrade install-docker install-crowdsec check-swap setup-dirs check-python setup-env verify-lespass check-traefik
	@echo -e "\n${GREEN}🎉 VPS setup completed successfully!${NC}"

# VPS update and upgrade
.PHONY: update-upgrade
update-upgrade:
	@echo -e "\n${YELLOW}🔄 Starting VPS update && upgrade...${NC}"
	sudo apt update && sudo apt upgrade -y
	sudo apt install git byobu curl
	@echo -e "${GREEN}✅ VPS update && upgrade completed successfully!${NC}"


# Docker installation
.PHONY: install-docker
install-docker:
	@echo -e "\n${YELLOW}🐳 Checking Docker installation...${NC}"
	@if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then \
		echo -e "${GREEN}✅ Docker is already installed and running!${NC}"; \
		# Ensure frontend network exists even if Docker was already installed \
		if ! docker network ls | grep -q frontend; then \
			echo -e "${YELLOW}🔄 Creating frontend network...${NC}"; \
			sudo docker network create frontend; \
			echo -e "${GREEN}✅ Frontend network created!${NC}"; \
		else \
			echo -e "${GREEN}✅ Frontend network already exists!${NC}"; \
		fi; \
	else \
		echo -e "${YELLOW}🔄 Installing Docker...${NC}"; \
		curl -fsSL https://get.docker.com -o get-docker.sh; \
		sudo sh get-docker.sh; \
		sudo usermod -aG docker $(USER); \
		rm get-docker.sh; \
		sudo docker network create frontend; \
		echo -e "${GREEN}✅ Docker installation completed successfully!${NC}"; \
	fi

# CrowdSec installation
.PHONY: install-crowdsec
install-crowdsec:
	@echo -e "\n${YELLOW}🛡️ Checking CrowdSec installation...${NC}"
	@if command -v cscli >/dev/null 2>&1 && systemctl is-active --quiet crowdsec 2>/dev/null; then \
		echo -e "${GREEN}✅ CrowdSec is already installed and running!${NC}"; \
		# Check if bouncer is installed \
		if systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null; then \
			echo -e "${GREEN}✅ CrowdSec firewall bouncer is already installed and running!${NC}"; \
		else \
			echo -e "${YELLOW}🔄 Installing CrowdSec firewall bouncer...${NC}"; \
			sudo apt install -y crowdsec-firewall-bouncer-iptables; \
			echo -e "${GREEN}✅ CrowdSec firewall bouncer installed successfully!${NC}"; \
		fi; \
	else \
		echo -e "${YELLOW}🔄 Installing CrowdSec...${NC}"; \
		curl -s https://install.crowdsec.net | sudo sh; \
		sudo apt install -y crowdsec; \
		sudo apt install -y crowdsec-firewall-bouncer-iptables; \
		echo -e "${GREEN}✅ CrowdSec installation completed successfully!${NC}"; \
	fi

# Check and configure swap space
.PHONY: check-swap
check-swap:
	@echo -e "\n${YELLOW}💾 Checking swap configuration...${NC}"
	@if swapon --show | grep -q "/swapfile"; then \
		echo -e "${GREEN}✅ Swap is already configured and active!${NC}"; \
		swapon --show; \
	else \
		echo -e "${YELLOW}🔄 Configuring swap space...${NC}"; \
		echo -e "${YELLOW}📝 Creating 4GB swap file...${NC}"; \
		sudo fallocate -l 4G /swapfile; \
		echo -e "${YELLOW}🔒 Securing swap file...${NC}"; \
		sudo chmod 600 /swapfile; \
		echo -e "${YELLOW}🔧 Formatting swap file...${NC}"; \
		sudo mkswap /swapfile; \
		echo -e "${YELLOW}🔌 Activating swap...${NC}"; \
		sudo swapon /swapfile; \
		echo -e "${YELLOW}🔍 Verifying swap configuration...${NC}"; \
		swapon --show; \
		echo -e "${YELLOW}📋 Adding swap to /etc/fstab for persistence...${NC}"; \
		if ! grep -q "/swapfile none swap sw 0 0" /etc/fstab; then \
			echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null; \
		fi; \
		echo -e "${GREEN}✅ Swap configuration completed successfully!${NC}"; \
	fi

# Check Python installation and install required libraries
.PHONY: check-python
check-python:
	@echo -e "\n${YELLOW}🐍 Checking Python installation...${NC}"
	@if command -v python3 >/dev/null 2>&1; then \
		echo -e "${GREEN}✅ Python is installed:${NC}"; \
		python3 --version; \
	else \
		echo -e "${YELLOW}⚠️ Python is not installed. Installing Python...${NC}"; \
		sudo apt update && sudo apt install -y python3 python3-full; \
	fi

	@echo -e "\n${YELLOW}📚 Setting up virtual environment for Python libraries...${NC}"
	@# Check if python3-venv is installed
	@if ! dpkg -l | grep -q python3-venv; then \
		echo -e "${YELLOW}⚠️ python3-venv is not installed. Installing...${NC}"; \
		sudo apt update && sudo apt install -y python3-venv; \
	fi

	@if [ ! -d "venv" ]; then \
		echo -e "${YELLOW}🔧 Creating virtual environment...${NC}"; \
		python3 -m venv venv || { echo -e "${RED}❌ Failed to create virtual environment. Please check your Python installation.${NC}"; exit 1; }; \
	fi

	@echo -e "${YELLOW}🔌 Activating virtual environment and installing packages...${NC}"
	@if [ -f "venv/bin/activate" ]; then \
		. venv/bin/activate && pip install cryptography django && deactivate; \
		echo -e "${GREEN}✅ Python libraries installed in virtual environment${NC}"; \
	else \
		echo -e "${RED}❌ Virtual environment activation file not found. Creating virtual environment again...${NC}"; \
		rm -rf venv; \
		python3 -m venv venv || { echo -e "${RED}❌ Failed to create virtual environment. Please check your Python installation.${NC}"; exit 1; }; \
		. venv/bin/activate && pip install cryptography django && deactivate; \
		echo -e "${GREEN}✅ Python libraries installed in virtual environment${NC}"; \
	fi

	@echo -e "\n${YELLOW}🔍 Checking for required system tools...${NC}"
	@if ! command -v host >/dev/null 2>&1; then \
		echo -e "${YELLOW}⚙️ Installing dnsutils for host command...${NC}"; \
		sudo apt update && sudo apt install -y dnsutils; \
	fi
	@if ! command -v curl >/dev/null 2>&1; then \
		echo -e "${YELLOW}⚙️ Installing curl...${NC}"; \
		sudo apt update && sudo apt install -y curl; \
	fi
	@echo -e "${GREEN}✅ Python libraries and system tools installed successfully!${NC}"

# Create required directories
.PHONY: setup-dirs
setup-dirs:
	@echo -e "\n${YELLOW}📁 Creating required directories...${NC}"
	mkdir -p logs www backup database nginx ssh
	cp laboutik.conf nginx
	@echo -e "${GREEN}✅ Directories created successfully!${NC}"

# Create and configure .env file
.PHONY: setup-env
setup-env:
	@echo -e "\n${YELLOW}📝 Creating .env file...${NC}"
	@if [ -f .env ]; then \
		echo -e "${YELLOW}⚠️ .env file already exists. Backing up to .env.bak${NC}"; \
		cp .env .env.bak; \
	fi
	@cp .env.template .env

	@echo -e "\n${YELLOW}🔐 Generating secure keys...${NC}"
	@if [ ! -d "venv" ]; then \
		echo -e "${YELLOW}⚠️ Virtual environment not found. Running check-python first...${NC}"; \
		$(MAKE) check-python; \
	fi

	@echo -e "${YELLOW}🔑 Using virtual environment to generate keys...${NC}"
	@django_secret=$$(. venv/bin/activate && python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())" && deactivate) && \
	awk -v secret="$$django_secret" 'BEGIN{FS=OFS="="} $$1=="DJANGO_SECRET"{$$2="'\''" secret "'\''"}1' .env > .env.tmp && mv .env.tmp .env && \
	echo -e "${GREEN}✅ Generated DJANGO_SECRET key${NC}"

	@fernet_key=$$(. venv/bin/activate && python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode('utf-8'))" && deactivate) && \
	awk -v key="$$fernet_key" 'BEGIN{FS=OFS="="} $$1=="FERNET_KEY"{$$2="'\''" key "'\''"}1' .env > .env.tmp && mv .env.tmp .env && \
	echo -e "${GREEN}✅ Generated FERNET_KEY${NC}"

	@postgres_password=$$(. venv/bin/activate && python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode('utf-8'))" && deactivate) && \
	awk -v pass="$$postgres_password" 'BEGIN{FS=OFS="="} $$1=="POSTGRES_PASSWORD"{$$2="'\''" pass "'\''"}1' .env > .env.tmp && mv .env.tmp .env && \
	echo -e "${GREEN}✅ Generated POSTGRES_PASSWORD${NC}"

	@borg_passphrase=$$(. venv/bin/activate && python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode('utf-8'))" && deactivate) && \
	awk -v pass="$$borg_passphrase" 'BEGIN{FS=OFS="="} $$1=="BORG_PASSPHRASE"{$$2="'\''" pass "'\''"}1' .env > .env.tmp && mv .env.tmp .env && \
	echo -e "${GREEN}✅ Generated BORG_PASSPHRASE${NC}"

	@echo -e "\n${YELLOW}👤 Please enter values for the following variables:${NC}"
	@while true; do \
		read -p "🌐 DOMAIN (e.g., cashless.tibillet.localhost, without https:// and without trailing /): " domain; \
		if [[ "$$domain" == *"https://"* ]]; then \
			echo -e "${RED}❌ Error: Domain should not contain https://. Please enter only the domain name.${NC}"; \
		elif [[ "$$domain" == */ ]]; then \
			echo -e "${RED}❌ Error: Domain should not end with /. Please enter only the domain name.${NC}"; \
		else \
			# Verify domain resolves to an IP address \
			echo -e "${YELLOW}🔍 Verifying domain $$domain...${NC}"; \
			if ! host "$$domain" > /dev/null 2>&1; then \
				echo -e "${YELLOW}⚠️ Warning: Domain $$domain could not be resolved. This might be normal for local development.${NC}"; \
				read -p "Continue anyway? (y/n): " continue_anyway; \
				if [[ "$$continue_anyway" != "y" ]]; then \
					continue; \
				fi; \
			else \
				echo -e "${GREEN}✅ Domain $$domain resolves successfully.${NC}"; \
				# Get IP information \
				ip_info=$$(curl -s ipinfo.io); \
				echo -e "${YELLOW}🌍 Your IP information:${NC}"; \
				echo "$$ip_info"; \
			fi; \
			awk -v domain="$$domain" 'BEGIN{FS=OFS="="} $$1=="DOMAIN"{$$2="'\''" domain "'\''"}1' .env > .env.tmp && mv .env.tmp .env; \
			echo -e "${GREEN}✅ Domain set successfully!${NC}"; \
			break; \
		fi; \
	done

	@while true; do \
		read -p "📧 ADMIN_EMAIL: " admin_email; \
		if [[ ! "$$admin_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$$ ]]; then \
			echo -e "${RED}❌ Error: Invalid email format. Please enter a valid email address.${NC}"; \
		else \
			awk -v email="$$admin_email" 'BEGIN{FS=OFS="="} $$1=="ADMIN_EMAIL"{$$2="'\''" email "'\''"}1' .env > .env.tmp && mv .env.tmp .env; \
			echo -e "${GREEN}✅ Admin email set successfully!${NC}"; \
			break; \
		fi; \
	done

	@while true; do \
		read -p "🔗 FEDOW_URL (must start with https:// and end with /): " fedow_url; \
		if [[ ! "$$fedow_url" == https://* ]]; then \
			echo -e "${RED}❌ Error: FEDOW_URL must start with https://${NC}"; \
		elif [[ ! "$$fedow_url" == */ ]]; then \
			echo -e "${RED}❌ Error: FEDOW_URL must end with /${NC}"; \
		else \
			# Verify URL is accessible \
			echo -e "${YELLOW}🔍 Verifying FEDOW_URL $$fedow_url...${NC}"; \
			status_code=$$(curl -s -o /dev/null -w "%{http_code}" --insecure "$$fedow_url"); \
			if [[ "$$status_code" == "200" ]]; then \
				echo -e "${GREEN}✅ FEDOW_URL is accessible (HTTP 200 OK)${NC}"; \
				awk -v url="$$fedow_url" 'BEGIN{FS=OFS="="} $$1=="FEDOW_URL"{$$2="'\''" url "'\''"}1' .env > .env.tmp && mv .env.tmp .env; \
				echo -e "${GREEN}✅ FEDOW_URL set successfully!${NC}"; \
				break; \
			else \
				echo -e "${YELLOW}⚠️ Warning: FEDOW_URL returned HTTP status $$status_code${NC}"; \
				read -p "Continue anyway? (y/n): " continue_anyway; \
				if [[ "$$continue_anyway" == "y" ]]; then \
					awk -v url="$$fedow_url" 'BEGIN{FS=OFS="="} $$1=="FEDOW_URL"{$$2="'\''" url "'\''"}1' .env > .env.tmp && mv .env.tmp .env; \
					echo -e "${YELLOW}⚠️ FEDOW_URL set despite connection issues${NC}"; \
					break; \
				fi; \
			fi; \
		fi; \
	done

	@while true; do \
		read -p "🎫 LESPASS_TENANT_URL (must start with https:// and end with /): " lespass_url; \
		if [[ ! "$$lespass_url" == https://* ]]; then \
			echo -e "${RED}❌ Error: LESPASS_TENANT_URL must start with https://${NC}"; \
		elif [[ ! "$$lespass_url" == */ ]]; then \
			echo -e "${RED}❌ Error: LESPASS_TENANT_URL must end with /${NC}"; \
		else \
			# Verify URL is accessible \
			echo -e "${YELLOW}🔍 Verifying LESPASS_TENANT_URL $$lespass_url...${NC}"; \
			status_code=$$(curl -s -o /dev/null -w "%{http_code}" --insecure "$$lespass_url"); \
			if [[ "$$status_code" == "200" ]]; then \
				echo -e "${GREEN}✅ LESPASS_TENANT_URL is accessible (HTTP 200 OK)${NC}"; \
				awk -v url="$$lespass_url" 'BEGIN{FS=OFS="="} $$1=="LESPASS_TENANT_URL"{$$2="'\''" url "'\''"}1' .env > .env.tmp && mv .env.tmp .env; \
				echo -e "${GREEN}✅ LESPASS_TENANT_URL set successfully!${NC}"; \
				break; \
			else \
				echo -e "${YELLOW}⚠️ Warning: LESPASS_TENANT_URL returned HTTP status $$status_code${NC}"; \
				read -p "Continue anyway? (y/n): " continue_anyway; \
				if [[ "$$continue_anyway" == "y" ]]; then \
					awk -v url="$$lespass_url" 'BEGIN{FS=OFS="="} $$1=="LESPASS_TENANT_URL"{$$2="'\''" url "'\''"}1' .env > .env.tmp && mv .env.tmp .env; \
					echo -e "${YELLOW}⚠️ LESPASS_TENANT_URL set despite connection issues${NC}"; \
					break; \
				fi; \
			fi; \
		fi; \
	done

	@read -p "💰 MAIN_ASSET_NAME (e.g., TestCoin, FestivalCoin): " asset_name && \
	awk -v name="$$asset_name" 'BEGIN{FS=OFS="="} $$1=="MAIN_ASSET_NAME"{$$2="'\''" name "'\''"}1' .env > .env.tmp && mv .env.tmp .env && \
	echo -e "${GREEN}✅ MAIN_ASSET_NAME set successfully!${NC}"

	@echo -e "\n${GREEN}🎉 .env file created and configured with your values!${NC}"


# Check if Traefik container is running
.PHONY: check-traefik
check-traefik:
	@echo -e "\n${YELLOW}🔍 Checking if Traefik container is running...${NC}"
	@if docker ps --format '{{.Names}}' | grep -q "traefik"; then \
		echo -e "${GREEN}✅ Traefik container is running!${NC}"; \
		docker ps --filter "name=traefik" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"; \
	else \
		echo -e "${RED}❌ Traefik container is not running!${NC}"; \
		echo -e "${YELLOW}ℹ️ Attempting to check if Traefik image exists...${NC}"; \
		if docker images | grep -q "traefik"; then \
			echo -e "${YELLOW}🔄 Traefik image exists but container is not running.${NC}"; \
		else \
			echo -e "${RED}❌ Failed to see Traefik container. .${NC}"; \
		fi; \
	fi


# Verify LesPass connection
.PHONY: verify-lespass
verify-lespass:
	@echo -e "\n${YELLOW}🔄 Verifying connection with LesPass...${NC}"
	@if [ ! -f .env ]; then \
		echo -e "${RED}❌ Error: .env file not found. Please run 'make setup-env' first.${NC}"; \
		exit 1; \
	fi
	@source .env && \
	echo -e "${YELLOW}🔌 Connecting to LesPass at $$LESPASS_TENANT_URL...${NC}" && \
	max_attempts=10; \
	attempt=1; \
	success=false; \
	while [ $$attempt -le $$max_attempts ] && [ "$$success" = "false" ]; do \
		echo -e "${YELLOW}⏳ Attempt $$attempt of $$max_attempts...${NC}"; \
		response=$$(curl -s -X POST \
			-d "email=$$ADMIN_EMAIL" \
			-H "Content-Type: application/x-www-form-urlencoded" \
			"$$LESPASS_TENANT_URL"api/get_user_pub_pem/); \
		if [ $$? -eq 0 ] && [ -n "$$response" ]; then \
			echo "$$response"; \
			echo -e "\n${GREEN}✅ LesPass connection verified successfully!${NC}"; \
			success=true; \
		else \
			echo -e "${YELLOW}⚠️ Connection failed. Retrying in 1 second...${NC}"; \
			sleep 1; \
			attempt=$$((attempt + 1)); \
		fi; \
	done; \
	if [ "$$success" = "false" ]; then \
		echo -e "${RED}❌ Failed to connect to LesPass after $$max_attempts attempts.${NC}"; \
		exit 1; \
	fi
