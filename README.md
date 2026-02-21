# Claude Dashboard

**A beautiful, real-time command center for Claude Code power users.**

Monitor your AI coding sessions, manage system resources, and control multiple projects from a single browser tab.

![Claude Dashboard](https://img.shields.io/badge/Claude_Code-Dashboard-blueviolet?style=for-the-badge)
![Node.js](https://img.shields.io/badge/Node.js-18+-green?style=flat-square)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)

## Features

### Kanban Board
- Visual project management across 5 status columns
- Drag-and-drop between statuses
- Real-time sync with `projects-registry.json`
- Project launch directly from cards

### Session Guardian
- **RAM Monitor** - Real-time memory tracking with visual bar
- **Auto-Kill** - Sessions older than 4 hours terminated automatically
- **MCP Orphan Cleanup** - Detects and kills orphaned MCP server processes
- **Critical Protection** - Emergency cleanup when RAM drops below 1GB

### Quick Actions (from the dashboard)
- **Launch Daily/Weekly** - Start project sessions in Windows Terminal tabs
- **Optimize PC** - Free RAM by stopping unnecessary services and processes
- **Kill Zombies** - Remove stale sessions
- **Cleanup** - Full process cleanup
- **Open Projects** - Quick folder access

### Second Brain Integration
- Daily and weekly AI-generated synthesis
- RSS feed learning
- Knowledge base browser

### AI Chat
- Built-in Claude assistant
- Project context awareness
- Quick commands

## Screenshot

The dashboard includes:
- Header with project stats and navigation
- Token usage tracking bar
- Guardian panel with RAM monitoring + action buttons
- AI chat assistant
- Kanban board with all projects
- Dark/light theme toggle

## Installation

```bash
# Clone the repo
git clone https://github.com/eladjak/claude-dashboard.git

# Install dependencies
cd claude-dashboard
npm install

# Start the server
node server.js
# Dashboard: http://localhost:3456
# WebSocket: ws://localhost:3457
```

## Session Guardian (Windows)

The Session Guardian runs as a background service protecting your system:

```powershell
# Install as startup service
powershell -File session-guardian.ps1

# Check status
powershell -File session-guardian.ps1 -status

# Parameters
-MaxSessionHours 4      # Kill sessions older than N hours
-WarningRAMMB 2048      # Warning threshold (2GB)
-CriticalRAMMB 1024     # Critical threshold (1GB)
-CheckIntervalSec 30    # Check every N seconds
```

### What it does every 30 seconds:
1. Checks free RAM
2. If < 2GB: kills oldest Claude session
3. If < 1GB: kills ALL sessions except newest
4. If session > 4 hours old: kills it + all child processes
5. Every 5 minutes: cleans orphaned MCP processes

## Architecture

```
claude-dashboard/
  server.js          # HTTP + WebSocket server
  index.html         # Single-page app (no build step!)
  session-guardian.ps1  # Background RAM monitor
  optimize-pc.ps1    # System optimization script
  launch-smart.ps1   # Multi-project launcher
  manifest.json      # PWA manifest
  sw.js              # Service worker for offline
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Dashboard HTML |
| `/brain` | GET | Second Brain UI |
| `/reports` | GET | Agent Reports |
| `/api/guardian` | GET | Guardian status + RAM info |
| `/api/guardian/action` | POST | Execute actions (optimize, cleanup, launch, etc.) |
| `/api/agent-sessions` | GET | Night mission reports + progress |
| `/api/reports/list` | GET | Available reports |

## Tech Stack

- **Frontend**: Vanilla HTML/CSS/JS (zero build, zero frameworks)
- **Backend**: Node.js HTTP server + WebSocket (ws)
- **Guardian**: PowerShell background service
- **PWA**: Service worker + manifest for installable app

## Why No Framework?

This dashboard loads instantly (<100ms) because it's a single HTML file with inline CSS and JS. No React, no Vite, no build step. Just open and go. For a local tool that runs on `localhost`, this is the perfect architecture.

## License

MIT

## Author

Built with Claude Code by [@eladjak](https://github.com/eladjak)
