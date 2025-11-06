# Supabase Migration Tool - Web UI Guide

## 🎯 Overview

The Web UI provides a user-friendly interface to manage all Supabase migrations without using the command line. It's a wrapper around the existing 6 core scripts - **no changes to the scripts themselves**.

## 🚀 Quick Start

### Option 1: Using the Startup Script

```bash
./start-ui.sh
```

### Option 2: Using npm

```bash
npm start
```

### Option 3: Direct Node.js

```bash
node server.js
```

Then open your browser: **http://localhost:3000**

## 📋 Features

### 1. Migration Plan Tab
- Generate migration plans comparing source and target
- View what needs to be migrated
- See detailed comparison reports

**Usage:**
1. Select source environment (dev/test/prod)
2. Select target environment (dev/test/prod)
3. Click "Generate Migration Plan"
4. View the comparison report

### 2. Main Migration Tab
- Run complete migrations with all components
- Configure options:
  - ✅ Include Data (`--data`)
  - ✅ Include Auth Users (`--users`)
  - ✅ Include Files (`--files`)
  - ✅ Create Backup (`--backup`)
  - ✅ Dry Run (Preview only)

**Usage:**
1. Select source and target environments
2. Check desired options
3. Click "Run Complete Migration"
4. Monitor progress in real-time

### 3. Component Migrations Tab
Run individual component migrations independently:

- **Database Migration**: Schema, data, auth users
- **Storage Migration**: Buckets and files
- **Edge Functions**: Function code deployment
- **Secrets**: Secret keys migration

Each component has its own form with specific options.

### 4. History & Reports Tab
- View all past migrations
- Access migration reports (HTML)
- View migration logs
- View migration plans

**Features:**
- Click "View Report" to open HTML report in new tab
- Click "View Log" to see detailed migration log
- Automatic refresh to see latest migrations

## 🎨 UI Features

### Real-time Logs
- See migration progress in real-time
- Color-coded log output:
  - 🟢 Green: Success messages
  - 🔴 Red: Error messages
  - 🟡 Yellow: Warning messages

### Status Indicators
- **Running**: Migration in progress
- **Completed**: Migration finished successfully
- **Failed**: Migration encountered errors

### Responsive Design
- Works on desktop and tablet
- Modern, clean interface
- Easy to use for non-technical users

## 🔧 Technical Details

### Architecture
- **Backend**: Node.js Express server (`server.js`)
- **Frontend**: HTML/CSS/JavaScript (`ui.html`, `ui.js`)
- **API**: REST API endpoints for script execution
- **Scripts**: Existing bash scripts (unchanged)

### How It Works
1. User fills out form in UI
2. Frontend sends request to API
3. Server executes corresponding bash script
4. Script output is captured and returned
5. UI displays results and logs

### Script Execution
- All scripts run exactly as they would from command line
- No modifications to existing scripts
- All flags and options are preserved
- Environment variables from `.env.local` are used

## 📊 API Endpoints

### Migration Operations
- `POST /api/migration-plan` - Generate migration plan
- `POST /api/migration` - Run complete migration
- `POST /api/migration/database` - Run database migration
- `POST /api/migration/storage` - Run storage migration
- `POST /api/migration/edge-functions` - Run edge functions migration
- `POST /api/migration/secrets` - Run secrets migration

### Data Retrieval
- `GET /api/migrations` - List all migrations and plans
- `GET /api/migrations/:name/log` - Get migration log
- `GET /api/migrations/:name/report` - Get migration report
- `GET /api/info` - Server information

## ⚙️ Configuration

### Port Configuration
Default port is 3000. To use a different port:

```bash
PORT=8080 npm start
```

### Environment Variables
The server uses the same `.env.local` file as the scripts. Make sure all required variables are set:

- `SUPABASE_ACCESS_TOKEN`
- `SUPABASE_DEV_PROJECT_REF`, `SUPABASE_DEV_DB_PASSWORD`, etc.
- `SUPABASE_DEV_SERVICE_ROLE_KEY`, etc.

## 🛡️ Security Notes

- The UI runs locally by default (localhost)
- Scripts execute with the same permissions as the user running the server
- No authentication is built-in (add if exposing to network)
- All script outputs are logged for auditing

## 📝 Usage Examples

### Example 1: Generate Migration Plan
1. Go to "Migration Plan" tab
2. Select: Source = `dev`, Target = `test`
3. Click "Generate Migration Plan"
4. Review the comparison report

### Example 2: Run Complete Migration
1. Go to "Main Migration" tab
2. Select: Source = `dev`, Target = `test`
3. Check: `--data`, `--users`, `--files`, `--backup`
4. Click "Run Complete Migration"
5. Watch progress in real-time
6. View results in "History & Reports" tab

### Example 3: Run Individual Component
1. Go to "Component Migrations" tab
2. Select component (e.g., "Database Migration")
3. Fill in source, target, and options
4. Click "Run"
5. View results

## 🔍 Troubleshooting

### Server Won't Start
- Check if Node.js is installed: `node --version`
- Install dependencies: `npm install`
- Check if port 3000 is available

### Scripts Not Executing
- Ensure scripts are executable: `chmod +x scripts/*.sh`
- Check `.env.local` exists and has all required variables
- Verify script paths are correct

### Logs Not Showing
- Check browser console for errors
- Verify migration completed (check History tab)
- Check server logs for errors

### Reports Not Loading
- Check if migration completed successfully
- Verify report files exist in `backups/` directory
- Check file permissions

## 🎯 Best Practices

1. **Always generate a migration plan first** before running migrations
2. **Use dry-run mode** to preview changes
3. **Create backups** when migrating to production
4. **Review logs** after migration completes
5. **Test on dev/test** before production migrations

## 📚 Related Documentation

- `user_manual.html` - Detailed script documentation
- `WEB_UI_README.md` - Quick start guide
- `REFACTORING_COMPLETE.md` - Architecture overview

## 🚀 Next Steps

After starting the server:
1. Open http://localhost:3000 in your browser
2. Generate a migration plan to see what needs to be migrated
3. Run migrations with your desired options
4. Review reports and logs in the History tab

Happy migrating! 🎉

