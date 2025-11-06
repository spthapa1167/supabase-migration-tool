# Supabase Migration Tool - Web UI

A modern, user-friendly web interface for managing Supabase migrations.

## 🚀 Quick Start

### 1. Install Dependencies

```bash
npm install
```

### 2. Start the Web UI Server

```bash
npm start
```

Or:

```bash
node server.js
```

### 3. Open in Browser

Navigate to: **http://localhost:3000**

## 📋 Features

### Migration Plan
- Generate migration plans comparing source and target environments
- View comprehensive comparison reports in HTML format

### Main Migration
- Run complete migrations with all components
- Options:
  - Include data migration (`--data`)
  - Include auth users (`--users`)
  - Include storage files (`--files`)
  - Create backup (`--backup`)
  - Dry run mode (`--dry-run`)

### Component Migrations
Run individual component migrations:
- **Database Migration**: Schema, data, and auth users
- **Storage Migration**: Bucket configurations and files
- **Edge Functions Migration**: Function code and deployment
- **Secrets Migration**: Secret keys (values need manual update)

### History & Reports
- View all past migrations
- Access migration reports (HTML)
- View migration logs
- View migration plans

## 🎯 Usage

### Starting the Server

```bash
# Default port (3000)
npm start

# Custom port
PORT=8080 npm start
```

### Accessing the UI

Once the server is running, open your browser and navigate to:
- **Main UI**: http://localhost:3000
- **API Endpoint**: http://localhost:3000/api

## 📡 API Endpoints

The server provides REST API endpoints:

- `GET /api/info` - Server information
- `GET /api/migrations` - List all migrations and plans
- `GET /api/migrations/:name/log` - Get migration log
- `GET /api/migrations/:name/report` - Get migration report
- `POST /api/migration-plan` - Generate migration plan
- `POST /api/migration` - Run complete migration
- `POST /api/migration/database` - Run database migration
- `POST /api/migration/storage` - Run storage migration
- `POST /api/migration/edge-functions` - Run edge functions migration
- `POST /api/migration/secrets` - Run secrets migration

## 🔧 Configuration

The server uses environment variables from `.env.local` (same as the scripts).

Required environment variables:
- `SUPABASE_ACCESS_TOKEN`
- `SUPABASE_DEV_PROJECT_REF`, `SUPABASE_DEV_DB_PASSWORD`, etc.
- `SUPABASE_DEV_SERVICE_ROLE_KEY`, etc.

## 📝 Notes

- The web UI executes the same bash scripts - no changes to existing scripts
- All scripts remain fully functional from command line
- The UI is a wrapper that provides a user-friendly interface
- Logs and reports are saved in the same locations as before
- Real-time log streaming is available during migration execution

## 🛠️ Troubleshooting

### Port Already in Use

If port 3000 is already in use, specify a different port:

```bash
PORT=8080 npm start
```

### Scripts Not Found

Ensure you're running the server from the project root directory where the scripts are located.

### Permission Issues

Make sure the migration scripts are executable:

```bash
chmod +x scripts/*.sh
chmod +x scripts/components/*.sh
```

## 📚 Related Documentation

- See `user_manual.html` for detailed script documentation
- See `REFACTORING_COMPLETE.md` for architecture overview

