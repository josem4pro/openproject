#!/usr/bin/env bash
# OpenProject Installation Script - TDD Validated
# Purpose: Install OpenProject via Docker Compose with persistent storage
# Target: rtx server (Ubuntu 24.04)
# Persistence: /var/lib/openproject

set -euo pipefail

# === CONFIGURATION ===
REPO_ROOT="/home/jose/Repositorios/openproject"
DEPLOY_DIR="$REPO_ROOT/deploy/openproject-deploy"
PERSIST_DIR="/var/lib/openproject"
POSTGRES_DATA_DIR="$PERSIST_DIR/postgres-data"
OP_DATA_DIR="$PERSIST_DIR/op-data"
MAX_WAIT=600  # 10 minutes timeout
INTERVAL=15   # seconds between checks
OPENPROJECT_PORT=8080

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# === HELPER FUNCTIONS ===
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    echo -e "${GREEN}[TEST]${NC} $1"
}

# === TEST 2: CHECK PREREQUISITES ===
check_prereqs() {
    log_info "Checking prerequisites..."

    # Test Docker
    if ! docker ps > /dev/null 2>&1; then
        log_error "Docker is not running or not accessible"
        exit 1
    fi
    log_test "PASS: Docker is operational"

    # Test docker-compose (standalone version)
    if ! command -v docker-compose &> /dev/null; then
        log_error "docker-compose is not installed"
        log_info "Please install docker-compose or docker-compose-plugin"
        exit 1
    fi

    if ! docker-compose version > /dev/null 2>&1; then
        log_error "docker-compose is not functional"
        exit 1
    fi
    log_test "PASS: docker-compose is functional"

    # Test git
    if ! command -v git &> /dev/null; then
        log_error "git is not installed"
        exit 1
    fi
    log_test "PASS: git is available"

    # Test openssl
    if ! command -v openssl &> /dev/null; then
        log_error "openssl is not installed"
        exit 1
    fi
    log_test "PASS: openssl is available"

    log_info "All prerequisites satisfied"
}

# === TEST 1: SETUP PERSISTENCE DIRECTORY ===
setup_persistence_dir() {
    log_info "Setting up persistence directory at $PERSIST_DIR..."

    # Create main directory
    if [[ ! -d "$PERSIST_DIR" ]]; then
        sudo mkdir -p "$PERSIST_DIR"
        log_info "Created $PERSIST_DIR"
    fi

    # Create subdirectories
    if [[ ! -d "$POSTGRES_DATA_DIR" ]]; then
        sudo mkdir -p "$POSTGRES_DATA_DIR"
        log_info "Created $POSTGRES_DATA_DIR"
    fi

    if [[ ! -d "$OP_DATA_DIR" ]]; then
        sudo mkdir -p "$OP_DATA_DIR"
        log_info "Created $OP_DATA_DIR"
    fi

    # Set permissions (755 for directories, owned by root)
    sudo chmod 755 "$PERSIST_DIR"
    sudo chmod 755 "$POSTGRES_DATA_DIR"
    sudo chmod 755 "$OP_DATA_DIR"
    sudo chown root:root "$PERSIST_DIR"

    # Validate
    if [[ ! -d "$PERSIST_DIR" ]] || [[ ! -d "$POSTGRES_DATA_DIR" ]] || [[ ! -d "$OP_DATA_DIR" ]]; then
        log_error "Failed to create persistence directories"
        exit 1
    fi

    log_test "PASS: Persistence directories created at $PERSIST_DIR"
    ls -ld "$PERSIST_DIR" "$POSTGRES_DATA_DIR" "$OP_DATA_DIR"

    # Add hostname to /etc/hosts if not present
    if ! grep -q "op.rtx.local" /etc/hosts; then
        log_info "Adding op.rtx.local to /etc/hosts..."
        echo "127.0.0.1 op.rtx.local" | sudo tee -a /etc/hosts > /dev/null
        log_test "PASS: Added op.rtx.local to /etc/hosts"
    else
        log_info "op.rtx.local already in /etc/hosts"
    fi
}

# === TEST 3: CLONE DEPLOY REPOSITORY ===
clone_deploy_repo() {
    log_info "Cloning OpenProject deploy repository..."

    # Create deploy directory if needed
    mkdir -p "$REPO_ROOT/deploy"

    if [[ -d "$DEPLOY_DIR" ]]; then
        if [[ -f "$DEPLOY_DIR/docker-compose.yml" ]]; then
            log_warn "Deploy directory already exists with docker-compose.yml"
            log_info "Pulling latest changes..."
            cd "$DEPLOY_DIR"
            git pull origin stable/14 || log_warn "Could not pull latest changes"
            cd "$REPO_ROOT"
        else
            log_error "Deploy directory exists but is incomplete. Removing and re-cloning..."
            rm -rf "$DEPLOY_DIR"
        fi
    fi

    if [[ ! -d "$DEPLOY_DIR" ]]; then
        git clone https://github.com/opf/openproject-deploy \
            --depth=1 \
            --branch=stable/14 \
            "$DEPLOY_DIR"
    fi

    # Validate
    if [[ ! -f "$DEPLOY_DIR/docker-compose.yml" ]]; then
        log_error "docker-compose.yml not found in $DEPLOY_DIR"
        exit 1
    fi

    log_test "PASS: OpenProject deploy repository cloned successfully"
    ls -la "$DEPLOY_DIR" | head -10
}

# === TEST 4: GENERATE .ENV FILE ===
generate_env_file() {
    log_info "Generating .env file with secure credentials..."

    cd "$DEPLOY_DIR"

    # Generate secure values
    SECRET_KEY=$(openssl rand -hex 32)
    POSTGRES_PASS=$(openssl rand -base64 32 | tr -d '\n' | tr -d '/')

    # Create .env file
    cat > .env << EOF
# OpenProject Environment Configuration
# Generated by install_openproject.sh on $(date)

# Database credentials
POSTGRES_PASSWORD=${POSTGRES_PASS}

# OpenProject secret key (64 hex characters)
SECRET_KEY_BASE=${SECRET_KEY}

# Host configuration
OPENPROJECT_HOST__NAME=op.rtx.local
OPENPROJECT_HTTPS=false

# Port mapping
PORT=${OPENPROJECT_PORT}
EOF

    # Set secure permissions on .env file
    chmod 600 .env

    # Validate
    if [[ ! -f .env ]]; then
        log_error "Failed to create .env file"
        exit 1
    fi

    if ! grep -q "SECRET_KEY_BASE=" .env; then
        log_error ".env file missing SECRET_KEY_BASE"
        exit 1
    fi

    if ! grep -q "POSTGRES_PASSWORD=" .env; then
        log_error ".env file missing POSTGRES_PASSWORD"
        exit 1
    fi

    log_test "PASS: .env file generated with secure credentials"
    log_info "SECRET_KEY_BASE length: ${#SECRET_KEY} characters"

    cd "$REPO_ROOT"
}

# === TEST 5: PATCH COMPOSE VOLUMES ===
patch_compose_volumes() {
    log_info "Configuring persistent volumes in docker-compose.yml..."

    cd "$DEPLOY_DIR"

    # Backup original
    if [[ ! -f docker-compose.yml.original ]]; then
        cp docker-compose.yml docker-compose.yml.original
        log_info "Backed up original docker-compose.yml"
    fi

    # Create docker-compose.override.yml for volume customization
    # This is the recommended way to customize without modifying the main file
    cat > docker-compose.override.yml << EOF
# OpenProject Volume Override
# Configures persistent storage at /var/lib/openproject
# Generated by install_openproject.sh on $(date)

services:
  db:
    volumes:
      - ${POSTGRES_DATA_DIR}:/var/lib/postgresql/data

  cache:
    volumes:
      - ${OP_DATA_DIR}/cache:/data

  web:
    volumes:
      - ${OP_DATA_DIR}/assets:/app/public/assets
    environment:
      - SECRET_KEY_BASE=\${SECRET_KEY_BASE}
      - DATABASE_URL=postgres://postgres:\${POSTGRES_PASSWORD}@db/openproject?pool=20&encoding=unicode&reconnect=true
      - RAILS_MIN_THREADS=4
      - RAILS_MAX_THREADS=16
      - OPENPROJECT_HOST__NAME=\${OPENPROJECT_HOST__NAME}
      - OPENPROJECT_HTTPS=\${OPENPROJECT_HTTPS}

  worker:
    environment:
      - SECRET_KEY_BASE=\${SECRET_KEY_BASE}
      - DATABASE_URL=postgres://postgres:\${POSTGRES_PASSWORD}@db/openproject?pool=20&encoding=unicode&reconnect=true
      - RAILS_MIN_THREADS=4
      - RAILS_MAX_THREADS=16

  seeder:
    environment:
      - SECRET_KEY_BASE=\${SECRET_KEY_BASE}
      - DATABASE_URL=postgres://postgres:\${POSTGRES_PASSWORD}@db/openproject?pool=20&encoding=unicode&reconnect=true

  cron:
    environment:
      - SECRET_KEY_BASE=\${SECRET_KEY_BASE}
      - DATABASE_URL=postgres://postgres:\${POSTGRES_PASSWORD}@db/openproject?pool=20&encoding=unicode&reconnect=true

  proxy:
    ports:
      - "${OPENPROJECT_PORT}:80"
EOF

    # Validate the configuration
    if ! docker-compose config > /dev/null 2>&1; then
        log_error "docker-compose config validation failed"
        docker-compose config 2>&1 | head -20
        exit 1
    fi

    log_test "PASS: docker-compose configuration validated"
    log_info "Volumes configured to use $PERSIST_DIR"

    cd "$REPO_ROOT"
}

# === TEST 6: START STACK ===
start_stack() {
    log_info "Starting OpenProject stack..."

    cd "$DEPLOY_DIR"

    # Pull images first
    log_info "Pulling Docker images (this may take a while)..."
    docker-compose pull

    # Start services
    log_info "Starting services with docker-compose up -d..."
    if ! docker-compose up -d; then
        log_error "Failed to start OpenProject stack"
        docker-compose logs 2>&1 | tail -50
        exit 1
    fi

    log_test "PASS: OpenProject stack started"
    docker-compose ps

    cd "$REPO_ROOT"
}

# === TEST 7 (Part 1): WAIT FOR READINESS ===
wait_for_readiness() {
    log_info "Waiting for OpenProject to be ready (max ${MAX_WAIT}s)..."

    cd "$DEPLOY_DIR"

    local elapsed=0
    local ready=false

    while [[ $elapsed -lt $MAX_WAIT ]]; do
        # Check container health
        local running_count
        running_count=$(docker-compose ps --filter "status=running" 2>/dev/null | grep -c "Up" || echo "0")

        log_info "Elapsed: ${elapsed}s | Running containers: $running_count"

        # Check logs for readiness indicators
        if docker-compose logs web 2>&1 | grep -q "Listening on"; then
            log_info "Web service indicates it's listening"
        fi

        # Try HTTP request (use /login to avoid redirect issues)
        local http_code
        http_code=$(curl -s -o /tmp/openproject_test.html -w "%{http_code}" "http://op.rtx.local:${OPENPROJECT_PORT}/login" 2>/dev/null || echo "000")

        if [[ "$http_code" == "200" ]]; then
            log_info "HTTP 200 received! Checking content..."
            if grep -q "OpenProject" /tmp/openproject_test.html 2>/dev/null; then
                ready=true
                break
            else
                log_warn "HTTP 200 but 'OpenProject' not found in response yet"
            fi
        elif [[ "$http_code" == "302" ]]; then
            log_info "Service responding (HTTP 302 redirect)..."
        elif [[ "$http_code" == "502" ]] || [[ "$http_code" == "503" ]]; then
            log_info "Service starting (HTTP $http_code)..."
        elif [[ "$http_code" != "000" ]]; then
            log_info "HTTP response: $http_code"
        fi

        sleep "$INTERVAL"
        elapsed=$((elapsed + INTERVAL))
    done

    cd "$REPO_ROOT"

    if [[ "$ready" != "true" ]]; then
        log_error "OpenProject did not become ready within ${MAX_WAIT} seconds"
        log_error "Showing recent logs:"
        cd "$DEPLOY_DIR"
        docker-compose logs --tail=100 2>&1
        cd "$REPO_ROOT"
        exit 1
    fi

    log_test "PASS: OpenProject is responding"
}

# === TEST 7 (Part 2): VALIDATE HTTP RESPONSE ===
validate_http() {
    log_info "Performing final HTTP validation..."

    local http_code
    # Use /login endpoint to get direct 200 response without redirect
    http_code=$(curl -s -o /tmp/openproject_final.html -w "%{http_code}" "http://op.rtx.local:${OPENPROJECT_PORT}/login" 2>/dev/null || echo "000")

    # Test 1: HTTP 200
    if [[ "$http_code" != "200" ]]; then
        log_error "CRITICAL TEST FAILED: HTTP response is $http_code, expected 200"
        exit 1
    fi
    log_test "PASS: HTTP 200 OK"

    # Test 2: Contains "OpenProject"
    if ! grep -q "OpenProject" /tmp/openproject_final.html 2>/dev/null; then
        log_error "CRITICAL TEST FAILED: Response does not contain 'OpenProject'"
        log_error "Response preview:"
        head -20 /tmp/openproject_final.html
        exit 1
    fi
    log_test "PASS: Response contains 'OpenProject'"

    # Additional validation: Check key services
    log_info "Checking service status..."
    cd "$DEPLOY_DIR"
    docker-compose ps
    cd "$REPO_ROOT"

    log_test "PASS: All critical HTTP validations passed"
    log_info "OpenProject is accessible at http://op.rtx.local:${OPENPROJECT_PORT}"
}

# === TEST 8: WRITE SUCCESS ARTIFACTS ===
write_success_artifacts() {
    log_info "Writing success artifacts..."

    # Create sprint directory if needed
    mkdir -p "$REPO_ROOT/sprint_2_rtx"

    # Write success artifact
    cat > "$REPO_ROOT/sprint_2_rtx/openproject_instalado.txt" << EOF
OpenProject Installation Success Report
========================================
Date: $(date)
Host: $(hostname)
User: $(whoami)
Repository: $REPO_ROOT

OpenProject Version: stable/14 (Docker Deploy)
Persistence Directory: $PERSIST_DIR
  - PostgreSQL Data: $POSTGRES_DATA_DIR
  - OpenProject Data: $OP_DATA_DIR

Access URL: http://op.rtx.local:${OPENPROJECT_PORT}
Local URL: http://localhost:${OPENPROJECT_PORT}

Default Credentials:
  Username: admin
  Password: admin
  !! CHANGE IMMEDIATELY AFTER FIRST LOGIN !!

Services Status:
$(cd "$DEPLOY_DIR" && docker-compose ps 2>/dev/null)

Installation completed successfully.
All TDD validations passed:
  [x] Persistence directories created
  [x] Docker prerequisites verified
  [x] Deploy repository cloned
  [x] Environment file generated
  [x] Volumes configured for persistence
  [x] Stack started without errors
  [x] HTTP 200 response received
  [x] 'OpenProject' found in response

This file serves as proof of successful installation.
EOF

    # Create documentation directory
    mkdir -p "$REPO_ROOT/docs/openproject"

    # Write README documentation
    cat > "$REPO_ROOT/docs/openproject/README.md" << EOF
# OpenProject - Sistema Central de Gestión de Proyectos

## Descripción

OpenProject es el **"cerebro HRM"** del ecosistema de la Conciencia Distribuida.
Funciona como el sistema central de gestión de proyectos para coordinar trabajo,
tareas y equipos a través de todas las máquinas y repositorios del sistema.

## Información de Instalación

- **Fecha de instalación**: $(date)
- **Versión**: stable/14 (Docker Deploy)
- **Servidor**: rtx (Ubuntu 24.04)
- **Método**: Docker Compose con persistencia local

## Ubicación de Datos Persistentes

Los datos de OpenProject se almacenan de forma persistente en:

\`\`\`
/var/lib/openproject/
├── postgres-data/    # Base de datos PostgreSQL
└── op-data/          # Assets y cache de OpenProject
    ├── assets/
    └── cache/
\`\`\`

**IMPORTANTE**: Estos directorios contienen todos los datos de proyectos, usuarios
y configuraciones. Asegúrate de incluirlos en tus estrategias de backup.

## Acceso

- **URL Principal**: http://op.rtx.local:${OPENPROJECT_PORT}
- **URL Local**: http://localhost:${OPENPROJECT_PORT}

Para acceder desde otras máquinas de la red, asegúrate de:
1. Agregar \`op.rtx.local\` a tu archivo \`/etc/hosts\` apuntando a la IP de rtx
2. O usar directamente la IP: \`http://192.168.0.103:${OPENPROJECT_PORT}\`

## Credenciales por Defecto

\`\`\`
Usuario: admin
Contraseña: admin
\`\`\`

⚠️ **CAMBIA ESTAS CREDENCIALES INMEDIATAMENTE DESPUÉS DEL PRIMER LOGIN** ⚠️

## Comandos de Gestión

Todos los comandos se ejecutan desde el directorio de deploy:

\`\`\`bash
cd ${DEPLOY_DIR}
\`\`\`

### Iniciar servicios
\`\`\`bash
docker-compose up -d
\`\`\`

### Detener servicios
\`\`\`bash
docker-compose stop
\`\`\`

### Reiniciar servicios
\`\`\`bash
docker-compose restart
\`\`\`

### Ver logs en tiempo real
\`\`\`bash
docker-compose logs -f
\`\`\`

### Ver logs de un servicio específico
\`\`\`bash
docker-compose logs -f web
docker-compose logs -f db
docker-compose logs -f worker
\`\`\`

### Ver estado de los servicios
\`\`\`bash
docker-compose ps
\`\`\`

### Recrear servicios (después de cambios en configuración)
\`\`\`bash
docker-compose up -d --force-recreate
\`\`\`

## Arquitectura de Servicios

OpenProject se compone de varios contenedores Docker:

- **web**: Servidor web principal (Puma/Rails)
- **worker**: Procesador de trabajos en segundo plano
- **cron**: Tareas programadas
- **seeder**: Inicialización de datos
- **db**: Base de datos PostgreSQL
- **cache**: Cache con Memcached
- **proxy**: Proxy reverso (nginx)

## Backup y Restauración

### Backup de la base de datos
\`\`\`bash
cd ${DEPLOY_DIR}
docker-compose exec db pg_dump -U postgres openproject > backup_\$(date +%Y%m%d).sql
\`\`\`

### Backup completo del directorio de datos
\`\`\`bash
sudo tar -czf openproject_backup_\$(date +%Y%m%d).tar.gz /var/lib/openproject/
\`\`\`

## Solución de Problemas

### Los servicios no inician
\`\`\`bash
# Ver logs detallados
docker-compose logs --tail=100

# Verificar configuración
docker-compose config
\`\`\`

### Error de conexión a base de datos
\`\`\`bash
# Reiniciar servicio de base de datos
docker-compose restart db

# Verificar que el contenedor está corriendo
docker-compose ps db
\`\`\`

### Limpiar y reiniciar todo
\`\`\`bash
docker-compose down
docker-compose up -d
\`\`\`

## Integración con el Ecosistema

OpenProject está diseñado para integrarse con:

- **Centro Consciente**: Sistema de memoria colectiva
- **GitHub Actions Runner**: CI/CD en rtx
- **Otros repositorios**: DungeonFighterFuente, zelcarwonder, etc.

## Mantenimiento

### Actualización de OpenProject
\`\`\`bash
cd ${DEPLOY_DIR}
git pull origin stable/14
docker-compose pull
docker-compose up -d
\`\`\`

### Limpieza de recursos Docker
\`\`\`bash
# Limpiar imágenes no utilizadas
docker image prune -f

# Limpiar volúmenes huérfanos (¡CUIDADO!)
# docker volume prune -f
\`\`\`

---

**Instalado por**: scripts/install_openproject.sh
**Validado con**: Test-Driven Development (TDD)
**Última actualización**: $(date)
EOF

    # Validate artifacts
    if [[ ! -f "$REPO_ROOT/sprint_2_rtx/openproject_instalado.txt" ]]; then
        log_error "Failed to create success artifact"
        exit 1
    fi

    if [[ ! -f "$REPO_ROOT/docs/openproject/README.md" ]]; then
        log_error "Failed to create README documentation"
        exit 1
    fi

    log_test "PASS: Success artifacts created"
    log_info "Created: sprint_2_rtx/openproject_instalado.txt"
    log_info "Created: docs/openproject/README.md"
}

# === MAIN EXECUTION ===
main() {
    echo "======================================"
    echo "OpenProject Installation Script"
    echo "TDD-Validated Deployment"
    echo "======================================"
    echo ""

    log_info "Starting installation process..."
    log_info "Repository root: $REPO_ROOT"
    log_info "Deploy directory: $DEPLOY_DIR"
    log_info "Persistence directory: $PERSIST_DIR"
    echo ""

    check_prereqs
    echo ""

    setup_persistence_dir
    echo ""

    clone_deploy_repo
    echo ""

    generate_env_file
    echo ""

    patch_compose_volumes
    echo ""

    start_stack
    echo ""

    wait_for_readiness
    echo ""

    validate_http
    echo ""

    write_success_artifacts
    echo ""

    echo "======================================"
    log_info "INSTALLATION COMPLETE"
    echo "======================================"
    echo ""
    log_info "OpenProject is now running at:"
    log_info "  - Local: http://localhost:${OPENPROJECT_PORT}"
    log_info "  - Network: http://op.rtx.local:${OPENPROJECT_PORT}"
    echo ""
    log_info "Default credentials: admin / admin"
    log_warn "CHANGE PASSWORD IMMEDIATELY AFTER FIRST LOGIN!"
    echo ""
    log_info "Artifacts created:"
    log_info "  - sprint_2_rtx/openproject_instalado.txt"
    log_info "  - docs/openproject/README.md"
    echo ""
    log_info "All TDD tests passed successfully!"
}

# Run main function
main "$@"
