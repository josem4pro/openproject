# OpenProject - Sistema Central de Gestión de Proyectos

## Descripción

OpenProject es el **"cerebro HRM"** del ecosistema de la Conciencia Distribuida.
Funciona como el sistema central de gestión de proyectos para coordinar trabajo,
tareas y equipos a través de todas las máquinas y repositorios del sistema.

## Información de Instalación

- **Fecha de instalación**: 2025-11-15
- **Versión**: stable/14 (Docker Deploy)
- **Servidor**: rtx (Ubuntu 24.04)
- **Método**: Docker Compose con persistencia local

## Ubicación de Datos Persistentes

Los datos de OpenProject se almacenan de forma persistente en:

```
/var/lib/openproject/
├── postgres-data/    # Base de datos PostgreSQL
└── op-data/          # Assets y cache de OpenProject
    ├── assets/
    └── cache/
```

**IMPORTANTE**: Estos directorios contienen todos los datos de proyectos, usuarios
y configuraciones. Asegúrate de incluirlos en tus estrategias de backup.

## Acceso

- **URL Principal**: http://op.rtx.local:8080
- **URL Local**: http://localhost:8080 (requiere Host header correcto)

Para acceder desde otras máquinas de la red, asegúrate de:
1. Agregar `op.rtx.local` a tu archivo `/etc/hosts` apuntando a la IP de rtx
2. O usar directamente la IP: `http://192.168.0.103:8080`

**Nota**: El hostname `op.rtx.local` ya está configurado en `/etc/hosts` del servidor rtx.

## Credenciales por Defecto

```
Usuario: admin
Contraseña: admin
```

**CAMBIA ESTAS CREDENCIALES INMEDIATAMENTE DESPUÉS DEL PRIMER LOGIN**

## Comandos de Gestión

Todos los comandos se ejecutan desde el directorio de deploy:

```bash
cd /home/jose/Repositorios/openproject/deploy/openproject-deploy
```

### Iniciar servicios
```bash
docker-compose up -d
```

### Detener servicios
```bash
docker-compose stop
```

### Reiniciar servicios
```bash
docker-compose restart
```

### Ver logs en tiempo real
```bash
docker-compose logs -f
```

### Ver logs de un servicio específico
```bash
docker-compose logs -f web
docker-compose logs -f db
docker-compose logs -f worker
```

### Ver estado de los servicios
```bash
docker-compose ps
```

### Recrear servicios (después de cambios en configuración)
```bash
docker-compose up -d --force-recreate
```

## Arquitectura de Servicios

OpenProject se compone de varios contenedores Docker:

- **web**: Servidor web principal (Puma/Rails)
- **worker**: Procesador de trabajos en segundo plano
- **cron**: Tareas programadas
- **seeder**: Inicialización de datos
- **db**: Base de datos PostgreSQL
- **cache**: Cache con Memcached
- **proxy**: Proxy reverso (Caddy)
- **autoheal**: Monitor de salud de contenedores

## Backup y Restauración

### Backup de la base de datos
```bash
cd /home/jose/Repositorios/openproject/deploy/openproject-deploy
docker-compose exec db pg_dump -U postgres openproject > backup_$(date +%Y%m%d).sql
```

### Backup completo del directorio de datos
```bash
sudo tar -czf openproject_backup_$(date +%Y%m%d).tar.gz /var/lib/openproject/
```

### Restauración de base de datos
```bash
cd /home/jose/Repositorios/openproject/deploy/openproject-deploy
docker-compose exec -T db psql -U postgres openproject < backup_YYYYMMDD.sql
```

## Solución de Problemas

### Los servicios no inician
```bash
# Ver logs detallados
docker-compose logs --tail=100

# Verificar configuración
docker-compose config
```

### Error "Invalid host_name configuration"
Este error ocurre cuando se accede via `localhost` en lugar de `op.rtx.local`.
Asegúrate de:
1. Usar `http://op.rtx.local:8080` en el navegador
2. Tener la entrada en `/etc/hosts`: `127.0.0.1 op.rtx.local`

### Error de conexión a base de datos
```bash
# Reiniciar servicio de base de datos
docker-compose restart db

# Verificar que el contenedor está corriendo
docker-compose ps db
```

### Limpiar y reiniciar todo
```bash
docker-compose down
docker-compose up -d
```

### Verificar salud del sistema
```bash
# Estado de contenedores
docker-compose ps

# Verificar que web está healthy
docker-compose ps web

# Test HTTP
curl -s -o /dev/null -w "%{http_code}" http://op.rtx.local:8080/login
# Debe retornar 200
```

## Integración con el Ecosistema

OpenProject está diseñado para integrarse con:

- **Centro Consciente**: Sistema de memoria colectiva
- **GitHub Actions Runner**: CI/CD en rtx
- **Otros repositorios**: DungeonFighterFuente, zelcarwonder, etc.

## Mantenimiento

### Actualización de OpenProject
```bash
cd /home/jose/Repositorios/openproject/deploy/openproject-deploy
git pull origin stable/14
docker-compose pull
docker-compose up -d
```

### Limpieza de recursos Docker
```bash
# Limpiar imágenes no utilizadas
docker image prune -f

# Limpiar volúmenes huérfanos (¡CUIDADO!)
# docker volume prune -f
```

### Monitoreo de recursos
```bash
# Ver uso de recursos por contenedor
docker stats --no-stream

# Ver espacio usado por volúmenes
sudo du -sh /var/lib/openproject/*
```

## Archivos de Configuración

- **Deploy directory**: `/home/jose/Repositorios/openproject/deploy/openproject-deploy/`
- **Docker Compose**: `docker-compose.yml` y `docker-compose.override.yml`
- **Variables de entorno**: `.env` (contiene SECRET_KEY_BASE y POSTGRES_PASSWORD)
- **Script de instalación**: `/home/jose/Repositorios/openproject/scripts/install_openproject.sh`

## Seguridad

- Los archivos `.env` tienen permisos 600 (solo lectura por owner)
- Las contraseñas son generadas aleatoriamente durante la instalación
- El SECRET_KEY_BASE es de 64 caracteres hexadecimales
- Se recomienda cambiar las credenciales de admin inmediatamente
- Considera configurar HTTPS para producción

---

**Instalado por**: scripts/install_openproject.sh
**Validado con**: Test-Driven Development (TDD)
**Artefacto de éxito**: sprint_2_rtx/openproject_instalado.txt
**Última actualización**: 2025-11-15
