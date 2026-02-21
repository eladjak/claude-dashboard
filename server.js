// Enhanced Dashboard Server with WebSocket, Launch, and Save support
// Usage: node ~/.claude/dashboard/server.js

const http = require('http');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const WebSocket = require('ws');

const HTTP_PORT = 3456;
const WS_PORT = 3457;
const CLAUDE_DIR = process.env.HOME || process.env.USERPROFILE;
const BASE_DIR = path.join(CLAUDE_DIR, '.claude');

const MIME_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.js': 'application/javascript',
    '.css': 'text/css',
    '.svg': 'image/svg+xml'
};

// Claude-Mem proxy helper
async function proxyClaudeMem(subPath, fullUrl) {
    const CLAUDE_MEM_PORT = 37777;
    const fetchUrl = (apiPath) => new Promise((resolve, reject) => {
        const reqOpts = { hostname: '127.0.0.1', port: CLAUDE_MEM_PORT, path: apiPath, method: 'GET', timeout: 5000 };
        const r = http.request(reqOpts, (res) => {
            let body = '';
            res.on('data', c => body += c);
            res.on('end', () => { try { resolve(JSON.parse(body)); } catch { resolve(body); } });
        });
        r.on('error', reject);
        r.on('timeout', () => { r.destroy(); reject(new Error('timeout')); });
        r.end();
    });

    const postUrl = (apiPath, data) => new Promise((resolve, reject) => {
        const payload = JSON.stringify(data);
        const reqOpts = { hostname: '127.0.0.1', port: CLAUDE_MEM_PORT, path: apiPath, method: 'POST', timeout: 5000, headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } };
        const r = http.request(reqOpts, (res) => {
            let body = '';
            res.on('data', c => body += c);
            res.on('end', () => { try { resolve(JSON.parse(body)); } catch { resolve(body); } });
        });
        r.on('error', reject);
        r.on('timeout', () => { r.destroy(); reject(new Error('timeout')); });
        r.write(payload);
        r.end();
    });

    if (!subPath || subPath === '') {
        // Main endpoint: health + observations + projects
        const [health, observations, projects] = await Promise.all([
            fetchUrl('/api/health').catch(() => ({ status: 'disconnected' })),
            fetchUrl('/api/observations').catch(() => []),
            fetchUrl('/api/projects').catch(() => [])
        ]);
        return { status: 'connected', health, observations, projects };
    } else if (subPath.startsWith('timeline')) {
        const urlObj = new URL(fullUrl, 'http://localhost');
        const anchor = urlObj.searchParams.get('anchor') || '';
        return await fetchUrl(`/api/timeline${anchor ? '?anchor=' + anchor : ''}`);
    } else if (subPath === 'save') {
        // Handled in POST
        return { error: 'Use POST method' };
    }
    return { error: 'Unknown claude-mem endpoint' };
}

// HTTP Server
const server = http.createServer(async (req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    res.setHeader('Cache-Control', 'no-cache');

    // Handle OPTIONS preflight
    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }

    // Handle POST requests
    if (req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            try {
                const data = JSON.parse(body);

                if (req.url === '/save-registry') {
                    const registryPath = path.join(BASE_DIR, 'projects-registry.json');
                    const content = JSON.stringify(data, null, 2);
                    fs.writeFileSync(registryPath, content, 'utf8');
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ success: true }));

                    // Broadcast update via WebSocket
                    broadcastUpdate();
                    return;
                }

                if (req.url === '/launch') {
                    const cmd = data.command;
                    // Open new terminal and run command
                    const minttyCmd = `mintty -e /bin/bash -c "${cmd.replace(/"/g, '\\"')}"`;
                    exec(minttyCmd, (error) => {
                        if (error) {
                            console.error('Launch error:', error);
                        }
                    });
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ success: true }));
                    return;
                }

                if (req.url === '/api/brain/claude-mem/save') {
                    try {
                        const payload = JSON.stringify(data);
                        const memReq = http.request({ hostname: '127.0.0.1', port: 37777, path: '/api/memory/save', method: 'POST', timeout: 5000, headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } }, (memRes) => {
                            let body = '';
                            memRes.on('data', c => body += c);
                            memRes.on('end', () => {
                                res.writeHead(200, { 'Content-Type': 'application/json' });
                                res.end(body);
                            });
                        });
                        memReq.on('error', (e) => {
                            res.writeHead(502, { 'Content-Type': 'application/json' });
                            res.end(JSON.stringify({ error: 'Claude-Mem unavailable: ' + e.message }));
                        });
                        memReq.write(payload);
                        memReq.end();
                    } catch(e) {
                        res.writeHead(502, { 'Content-Type': 'application/json' });
                        res.end(JSON.stringify({ error: e.message }));
                    }
                    return;
                }

                if (req.url === '/api/guardian/action') {
                    const action = data.action;
                    const scriptsDir = path.join(BASE_DIR, 'scripts');
                    let cmd = '';
                    switch (action) {
                        case 'optimize':
                            cmd = `powershell -ExecutionPolicy Bypass -File "${path.join(scriptsDir, 'optimize-pc.ps1')}" -aggressive`;
                            break;
                        case 'kill-zombies':
                            cmd = `powershell -ExecutionPolicy Bypass -File "${path.join(scriptsDir, 'kill-zombies.ps1')}"`;
                            break;
                        case 'cleanup':
                            cmd = `powershell -ExecutionPolicy Bypass -File "${path.join(scriptsDir, 'cleanup-all.ps1')}"`;
                            break;
                        case 'kill-all':
                            cmd = `powershell -ExecutionPolicy Bypass -File "${path.join(scriptsDir, 'launch-smart.ps1')}" --kill`;
                            break;
                        case 'launch-daily':
                            cmd = `powershell -ExecutionPolicy Bypass -File "${path.join(scriptsDir, 'launch-smart.ps1')}"`;
                            break;
                        case 'launch-weekly':
                            cmd = `powershell -ExecutionPolicy Bypass -File "${path.join(scriptsDir, 'launch-smart.ps1')}" --weekly`;
                            break;
                        case 'restart-guardian':
                            cmd = `wscript.exe "${path.join(scriptsDir, 'start-guardian.vbs')}"`;
                            break;
                        case 'open-folder':
                            cmd = `explorer.exe "${data.folder || 'C:\\Users\\eladj\\projects'}"`;
                            break;
                        case 'open-claude':
                            cmd = `wt new-tab --title "Claude Code" cmd /k "${path.join(process.env.APPDATA || '', 'npm', 'claude.cmd')}"`;
                            break;
                        default:
                            res.writeHead(400, { 'Content-Type': 'application/json' });
                            res.end(JSON.stringify({ error: 'Unknown action: ' + action }));
                            return;
                    }
                    exec(cmd, { timeout: 30000 }, (error, stdout, stderr) => {
                        if (error) console.error('Action error:', error.message);
                    });
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ success: true, action }));
                    return;
                }

                if (req.url === '/update-tokens') {
                    const tokenPath = path.join(BASE_DIR, 'token-usage.json');
                    const content = JSON.stringify(data, null, 2);
                    fs.writeFileSync(tokenPath, content, 'utf8');
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ success: true }));
                    broadcastUpdate();
                    return;
                }

            } catch (e) {
                console.error('POST error:', e);
            }
            res.writeHead(400);
            res.end('Bad request');
        });
        return;
    }

    // Handle GET requests
    let filePath;
    if (req.url === '/' || req.url === '/index.html') {
        filePath = path.join(BASE_DIR, 'dashboard', 'index.html');
    } else if (req.url === '/brain' || req.url === '/brain/') {
        filePath = path.join(BASE_DIR, 'second-brain', 'ui', 'index.html');
    } else if (req.url === '/reports' || req.url === '/reports/') {
        filePath = path.join(BASE_DIR, 'dashboard', 'reports', 'index.html');
    } else if (req.url === '/projects-registry.json') {
        filePath = path.join(BASE_DIR, 'projects-registry.json');
    } else if (req.url === '/token-usage.json') {
        filePath = path.join(BASE_DIR, 'token-usage.json');
    } else if (req.url.startsWith('/api/brain/')) {
        // Second Brain API
        const endpoint = req.url.replace('/api/brain/', '');
        const brainBase = path.join(BASE_DIR, 'second-brain');
        let data = {};
        try {
            if (endpoint === 'profile') {
                const profileDir = path.join(brainBase, 'profile');
                data = {};
                for (const f of fs.readdirSync(profileDir).filter(f => f.endsWith('.md'))) {
                    data[f.replace('.md','')] = fs.readFileSync(path.join(profileDir, f), 'utf8');
                }
            } else if (endpoint === 'knowledge') {
                data = { business: {}, technical: {}, personal: {} };
                for (const domain of ['business', 'technical', 'personal']) {
                    const dir = path.join(brainBase, 'knowledge', domain);
                    if (fs.existsSync(dir)) {
                        for (const f of fs.readdirSync(dir).filter(f => f.endsWith('.md') || f.endsWith('.json'))) {
                            const content = fs.readFileSync(path.join(dir, f), 'utf8');
                            data[domain][f.replace(/\.(md|json)$/,'')] = f.endsWith('.json') ? JSON.parse(content) : content;
                        }
                    }
                }
            } else if (endpoint === 'conversations') {
                const convPath = path.join(brainBase, 'knowledge', 'personal', 'conversation-history.json');
                if (fs.existsSync(convPath)) data = JSON.parse(fs.readFileSync(convPath, 'utf8'));
            } else if (endpoint === 'braindumps') {
                const rawDir = path.join(brainBase, 'braindumps', 'raw');
                data = [];
                if (fs.existsSync(rawDir)) {
                    for (const f of fs.readdirSync(rawDir).filter(f => f.endsWith('.md'))) {
                        data.push({ file: f, content: fs.readFileSync(path.join(rawDir, f), 'utf8') });
                    }
                }
            } else if (endpoint === 'stats') {
                const convPath = path.join(brainBase, 'knowledge', 'personal', 'conversation-history.json');
                const convData = fs.existsSync(convPath) ? JSON.parse(fs.readFileSync(convPath, 'utf8')) : {};
                const profileFiles = fs.existsSync(path.join(brainBase, 'profile')) ? fs.readdirSync(path.join(brainBase, 'profile')).length : 0;
                const rawDumps = fs.existsSync(path.join(brainBase, 'braindumps', 'raw')) ? fs.readdirSync(path.join(brainBase, 'braindumps', 'raw')).length : 0;
                const claudeExport = convData.claudeExport || {};
                data = {
                    profileFiles,
                    braindumps: rawDumps,
                    chatgptConversations: convData.chatgpt?.total || 0,
                    claudeConversations: convData.claude?.totalConversations || 0,
                    claudeProjects: convData.claude?.totalProjects || 0,
                    claudeExportConversations: claudeExport.total || 0,
                    claudeExportMessages: claudeExport.totalMessages || 0,
                    claudeExportProjects: claudeExport.projects || 0,
                    claudeExportTopics: claudeExport.topics || {},
                    lastAnalysis: convData.generatedAt || null
                };
            } else if (endpoint === 'creators') {
                const creatorsJsonPath = path.join(brainBase, 'knowledge', 'personal', 'creators-updates.json');
                const creatorsTrackingPath = path.join(brainBase, 'knowledge', 'personal', 'creators-tracking.md');
                if (fs.existsSync(creatorsJsonPath)) {
                    data = JSON.parse(fs.readFileSync(creatorsJsonPath, 'utf8'));
                }
                if (fs.existsSync(creatorsTrackingPath)) {
                    data.tracking = fs.readFileSync(creatorsTrackingPath, 'utf8');
                }
                // Auto-learn report
                const learnPath = path.join(brainBase, 'knowledge', 'technical', 'auto-learn-report.md');
                if (fs.existsSync(learnPath)) {
                    data.autoLearnReport = fs.readFileSync(learnPath, 'utf8');
                }
            } else if (endpoint === 'memories') {
                const memPath = path.join(brainBase, 'knowledge', 'personal', 'claude-memories.md');
                if (fs.existsSync(memPath)) data = { content: fs.readFileSync(memPath, 'utf8') };
            } else if (endpoint.startsWith('claude-mem')) {
                // Proxy to Claude-Mem HTTP API (port 37777)
                const subPath = endpoint.replace('claude-mem', '').replace(/^\//, '');
                try {
                    data = await proxyClaudeMem(subPath, req.url);
                } catch (e) {
                    data = { error: e.message, status: 'disconnected' };
                }
            }
        } catch(e) {
            console.error('Brain API error:', e);
        }
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(data));
        return;
    } else if (req.url === '/api/reports/list') {
        // Reports API - list all report files
        const homeDir = process.env.HOME || process.env.USERPROFILE;
        const docsDir = path.join(homeDir, 'Documents');
        const dailyDir = path.join(BASE_DIR, 'second-brain', 'daily');
        const weeklyDir = path.join(BASE_DIR, 'second-brain', 'weekly');

        const result = { missions: [], daily: [], weekly: [] };

        try {
            // Night mission reports from ~/Documents
            if (fs.existsSync(docsDir)) {
                const files = fs.readdirSync(docsDir).filter(f => f.startsWith('night-mission-report-') && f.endsWith('.md'));
                for (const f of files) {
                    const dateMatch = f.match(/(\d{4}-\d{2}-\d{2})/);
                    result.missions.push({
                        name: f.replace('.md', '').replace('night-mission-report-', 'משימת לילה '),
                        date: dateMatch ? dateMatch[1] : '',
                        path: path.join(docsDir, f)
                    });
                }
                result.missions.sort((a, b) => b.date.localeCompare(a.date));
            }

            // Daily synthesis
            if (fs.existsSync(dailyDir)) {
                const files = fs.readdirSync(dailyDir).filter(f => f.startsWith('daily-') && f.endsWith('.md'));
                for (const f of files) {
                    const dateMatch = f.match(/(\d{4}-\d{2}-\d{2})/);
                    result.daily.push({
                        name: f.replace('.md', '').replace('daily-', 'סיכום יומי '),
                        date: dateMatch ? dateMatch[1] : '',
                        path: path.join(dailyDir, f)
                    });
                }
                result.daily.sort((a, b) => b.date.localeCompare(a.date));
            }

            // Weekly synthesis
            if (fs.existsSync(weeklyDir)) {
                const files = fs.readdirSync(weeklyDir).filter(f => f.startsWith('synthesis-') && f.endsWith('.md'));
                for (const f of files) {
                    const dateMatch = f.match(/(\d{4}-\d{2}-\d{2})/);
                    result.weekly.push({
                        name: f.replace('.md', '').replace('synthesis-', 'סינתזה שבועית '),
                        date: dateMatch ? dateMatch[1] : '',
                        path: path.join(weeklyDir, f)
                    });
                }
                result.weekly.sort((a, b) => b.date.localeCompare(a.date));
            }
        } catch (e) {
            console.error('Reports list error:', e);
        }

        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(result));
        return;

    } else if (req.url.startsWith('/api/reports/content')) {
        // Reports API - get file content with path traversal protection
        const urlObj = new URL(req.url, 'http://localhost');
        const filePath2 = urlObj.searchParams.get('file');
        const homeDir = process.env.HOME || process.env.USERPROFILE;

        // Validate path - only allow files from known safe directories
        const allowedPrefixes = [
            path.join(homeDir, 'Documents'),
            path.join(BASE_DIR, 'second-brain', 'daily'),
            path.join(BASE_DIR, 'second-brain', 'weekly')
        ];

        const normalizedPath = path.resolve(filePath2 || '');
        const isAllowed = allowedPrefixes.some(prefix => normalizedPath.startsWith(prefix));

        if (!filePath2 || !isAllowed || !normalizedPath.endsWith('.md')) {
            res.writeHead(403, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Access denied' }));
            return;
        }

        try {
            const content = fs.readFileSync(normalizedPath, 'utf8');
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            res.end(JSON.stringify({ content }));
        } catch (e) {
            res.writeHead(404, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'File not found' }));
        }
        return;

    } else if (req.url === '/api/agent-sessions') {
        // Agent Sessions API - combines night missions + daily synthesis + project PROGRESS
        const homeDir = process.env.HOME || process.env.USERPROFILE;
        const docsDir = path.join(homeDir, 'Documents');
        const dailyDir = path.join(BASE_DIR, 'second-brain', 'daily');
        const registryPath = path.join(BASE_DIR, 'projects-registry.json');

        const result = { sessions: [], lastMission: null, stats: { totalMissions: 0, totalAgents: 0, totalSuccess: 0 } };

        try {
            // Parse registry for project paths
            const registry = fs.existsSync(registryPath) ? JSON.parse(fs.readFileSync(registryPath, 'utf8')) : { projects: [] };
            const projectMap = {};
            for (const p of registry.projects || []) {
                projectMap[p.id] = { name: p.name, icon: p.icon, status: p.status, folder: p.folder, lastSession: p.lastSession };
            }

            // Night mission reports
            if (fs.existsSync(docsDir)) {
                const missionFiles = fs.readdirSync(docsDir).filter(f => f.startsWith('night-mission-report-') && f.endsWith('.md'));
                missionFiles.sort().reverse();
                result.stats.totalMissions = missionFiles.length;

                for (const f of missionFiles.slice(0, 10)) {
                    const content = fs.readFileSync(path.join(docsDir, f), 'utf8');
                    const dateMatch = f.match(/(\d{4}-\d{2}-\d{2})/);
                    const date = dateMatch ? dateMatch[1] : '';

                    // Extract agent rows from table (# | project | task | agentId | status)
                    const agents = [];
                    const tableRows = content.match(/\|\s*\d+\s*\|[^|]+\|[^|]+\|[^|]+\|[^|]+\|/g) || [];
                    for (const row of tableRows) {
                        const cols = row.split('|').filter(c => c.trim()).map(c => c.trim());
                        if (cols.length >= 5 && !cols[0].includes('---') && /^[1-9]\d*$/.test(cols[0]) && /^a[0-9a-f]+$/i.test(cols[3])) {
                            agents.push({
                                num: cols[0],
                                project: cols[1],
                                task: cols[2],
                                agentId: cols[3],
                                status: cols[4]
                            });
                        }
                    }

                    const successCount = agents.filter(a => /הושלם|completed|success/i.test(a.status)).length;
                    result.stats.totalAgents += agents.length;
                    result.stats.totalSuccess += successCount;

                    // Extract executive summary
                    const summaryMatch = content.match(/## סיכום מנהלים\n([\s\S]*?)(?=\n---|\n##)/);
                    const summary = summaryMatch ? summaryMatch[1].trim() : '';

                    const session = { type: 'mission', date, file: f, agents, agentCount: agents.length, successCount, summary };
                    result.sessions.push(session);

                    if (!result.lastMission) result.lastMission = session;
                }
            }

            // Daily synthesis
            if (fs.existsSync(dailyDir)) {
                const dailyFiles = fs.readdirSync(dailyDir).filter(f => f.startsWith('daily-') && f.endsWith('.md'));
                dailyFiles.sort().reverse();
                for (const f of dailyFiles.slice(0, 10)) {
                    const content = fs.readFileSync(path.join(dailyDir, f), 'utf8');
                    const dateMatch = f.match(/(\d{4}-\d{2}-\d{2})/);
                    const date = dateMatch ? dateMatch[1] : '';

                    // Extract project list
                    const projectLines = content.match(/- .+\*\*.+\*\*.+/g) || [];
                    const projects = projectLines.map(l => {
                        const nameMatch = l.match(/\*\*(.+?)\*\*/);
                        const statusMatch = l.match(/\((.+?)\)/);
                        return { name: nameMatch ? nameMatch[1] : '', status: statusMatch ? statusMatch[1] : '' };
                    });

                    // Check if a mission exists for same date (don't duplicate)
                    if (!result.sessions.find(s => s.date === date && s.type === 'mission')) {
                        result.sessions.push({ type: 'daily', date, file: f, projects, projectCount: projects.length });
                    } else {
                        // Merge daily project info into existing mission session
                        const existing = result.sessions.find(s => s.date === date && s.type === 'mission');
                        if (existing) existing.dailyProjects = projects;
                    }
                }
            }

            // Read PROGRESS.md from active projects (last 7 days)
            const sevenDaysAgo = new Date();
            sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);
            const cutoffDate = sevenDaysAgo.toISOString().split('T')[0];

            const progressUpdates = [];
            for (const p of registry.projects || []) {
                if (p.lastSession >= cutoffDate && p.folder && p.status !== 'merged' && p.status !== 'paused') {
                    const progressPath = path.join(p.folder, 'PROGRESS.md');
                    if (fs.existsSync(progressPath)) {
                        try {
                            const content = fs.readFileSync(progressPath, 'utf8');
                            const lastUpdated = content.match(/Last Updated:\s*(.+)/i);
                            const statusMatch = content.match(/## Current State\n([\s\S]*?)(?=\n##|\n$)/);
                            const doneMatch = content.match(/## What Was Done\n([\s\S]*?)(?=\n##|\n$)/);
                            progressUpdates.push({
                                projectId: p.id,
                                projectName: p.name,
                                icon: p.icon,
                                lastUpdated: lastUpdated ? lastUpdated[1].trim() : p.lastSession,
                                currentState: statusMatch ? statusMatch[1].trim().substring(0, 300) : '',
                                whatWasDone: doneMatch ? doneMatch[1].trim().substring(0, 500) : ''
                            });
                        } catch { /* skip */ }
                    }
                }
            }
            result.progressUpdates = progressUpdates;

            // Sort sessions by date desc
            result.sessions.sort((a, b) => b.date.localeCompare(a.date));

        } catch (e) {
            console.error('Agent sessions error:', e);
        }

        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(result));
        return;

    } else if (req.url === '/api/guardian') {
        // Guardian Status API
        const guardianState = path.join(BASE_DIR, 'logs', 'guardian-state.json');
        const guardianPid = path.join(BASE_DIR, 'logs', 'guardian-pid.txt');
        const guardianLog = path.join(BASE_DIR, 'logs', 'session-guardian.log');

        const result = { running: false, pid: null, freeRAMMB: 0, sessionCount: 0, mcpCount: 0, lastCheck: null, recentLog: [] };

        try {
            // Read state file
            if (fs.existsSync(guardianState)) {
                const state = JSON.parse(fs.readFileSync(guardianState, 'utf8'));
                Object.assign(result, state);
            }
            // Check if guardian PID is alive
            if (fs.existsSync(guardianPid)) {
                result.pid = fs.readFileSync(guardianPid, 'utf8').trim();
                try {
                    process.kill(parseInt(result.pid), 0); // signal 0 = check if alive
                    result.running = true;
                } catch { result.running = false; }
            }
            // Get last 10 log lines
            if (fs.existsSync(guardianLog)) {
                const log = fs.readFileSync(guardianLog, 'utf8');
                result.recentLog = log.trim().split('\n').slice(-10);
            }
            // Get live RAM info via child process
            const { execSync } = require('child_process');
            const ramInfo = execSync('powershell -Command "$os = Get-CimInstance Win32_OperatingSystem; Write-Host ([math]::Round($os.FreePhysicalMemory/1KB)) ([math]::Round($os.TotalVisibleMemorySize/1KB))"', { timeout: 5000 }).toString().trim().split(' ');
            result.freeRAMMB = parseInt(ramInfo[0]) || 0;
            result.totalRAMMB = parseInt(ramInfo[1]) || 0;
        } catch (e) {
            console.error('Guardian API error:', e.message);
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
        return;

    } else if (req.url === '/api/guardian/action' && req.method === 'POST') {
        // Guardian action execution (called from POST handler above - this is GET fallback)
        res.writeHead(405); res.end('Use POST'); return;

    } else if (req.url === '/manifest.json') {
        filePath = path.join(BASE_DIR, 'dashboard', 'manifest.json');
    } else if (req.url === '/sw.js') {
        filePath = path.join(BASE_DIR, 'dashboard', 'sw.js');
    } else {
        res.writeHead(404);
        res.end('Not found');
        return;
    }

    const ext = path.extname(filePath);
    const contentType = MIME_TYPES[ext] || 'text/plain';

    fs.readFile(filePath, (err, content) => {
        if (err) {
            if (err.code === 'ENOENT') {
                if (ext === '.json') {
                    res.writeHead(200, { 'Content-Type': contentType });
                    res.end('{}');
                } else {
                    res.writeHead(404);
                    res.end('Not found');
                }
            } else {
                res.writeHead(500);
                res.end('Server error');
            }
            return;
        }
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(content);
    });
});

// WebSocket Server
let wss;
try {
    wss = new WebSocket.Server({ port: WS_PORT });
    console.log(`🔌 WebSocket server on ws://localhost:${WS_PORT}`);

    wss.on('connection', (ws) => {
        console.log('📱 Client connected');
        // Send initial data
        sendData(ws);
    });
} catch (e) {
    console.log('⚠️  WebSocket not available, using polling only');
}

function sendData(ws) {
    try {
        const registryPath = path.join(BASE_DIR, 'projects-registry.json');
        const tokenPath = path.join(BASE_DIR, 'token-usage.json');

        const projects = JSON.parse(fs.readFileSync(registryPath, 'utf8')).projects || [];
        const tokens = JSON.parse(fs.readFileSync(tokenPath, 'utf8')) || {};

        ws.send(JSON.stringify({
            type: 'update',
            projects,
            tokens
        }));
    } catch (e) {
        console.error('Send error:', e);
    }
}

function broadcastUpdate() {
    if (wss) {
        wss.clients.forEach(client => {
            if (client.readyState === WebSocket.OPEN) {
                sendData(client);
            }
        });
    }
}

// Watch for file changes
const registryPath = path.join(BASE_DIR, 'projects-registry.json');
const tokenPath = path.join(BASE_DIR, 'token-usage.json');

fs.watch(registryPath, { persistent: false }, () => {
    console.log('📁 Registry changed');
    broadcastUpdate();
});

fs.watch(tokenPath, { persistent: false }, () => {
    console.log('💰 Tokens changed');
    broadcastUpdate();
});

server.listen(HTTP_PORT, () => {
    console.log(`
╔══════════════════════════════════════════╗
║     🤖 Claude Dashboard Server           ║
╠══════════════════════════════════════════╣
║  📍 http://localhost:${HTTP_PORT}               ║
║  📂 ${BASE_DIR}  ║
║                                          ║
║  Features:                               ║
║  ✓ Real-time sync (WebSocket)           ║
║  ✓ Drag & Drop save                     ║
║  ✓ Direct project launch                ║
║  ✓ Token tracking                       ║
╚══════════════════════════════════════════╝

Press Ctrl+C to stop
`);
});
