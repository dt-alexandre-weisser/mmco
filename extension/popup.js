// Toolbar popup: shows the repo and branch detected on the current GitHub tab, the state of the
// last mmco run for that repo (live while it runs, through the background port), a Go button and a
// Stop button. Falls back to mmco:// URLs when the native host is unreachable.
const $ = (id) => document.getElementById(id);

const checkoutUrl = (repo, branch) =>
  `mmco://checkout?repo=${encodeURIComponent(repo)}&branch=${encodeURIComponent(branch)}`;

const activeTab = async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
};

// On a GitHub page the content script clicks an anchor (reliable protocol prompt). Elsewhere
// there is no content script, so the tab itself navigates to the mmco:// URL.
const openUrl = async (tab, url) => {
  try {
    const ok = await chrome.tabs.sendMessage(tab.id, { type: 'open', url });
    if (ok) return;
  } catch {
    // no content script on this tab
  }
  await chrome.tabs.update(tab.id, { url });
};

// "Slack it" message, edited here and read by the content script on each click.
const SLACK_TEMPLATE_DEFAULT = ':approved_stamp: {url} plz';

const initSlackTemplate = async () => {
  const field = $('slack-template');
  field.placeholder = SLACK_TEMPLATE_DEFAULT;
  const { slackTemplate } = await chrome.storage.sync.get('slackTemplate');
  field.value = slackTemplate || SLACK_TEMPLATE_DEFAULT;
  field.addEventListener('input', () => {
    chrome.storage.sync.set({ slackTemplate: field.value.trim() });
  });
};

const STATUS_TEXT = { none: '', running: 'running', done: 'checked out', failed: 'failed', stopped: 'stopped' };

const render = (state) => {
  const status = state?.status || 'none';
  document.body.dataset.status = status;
  $('status-text').textContent = STATUS_TEXT[status] ?? status;
  $('phase').textContent = status === 'none' ? '–' : (state.phase || '–');
  if (state?.branch) $('branch').textContent = state.branch;
  $('tail').textContent = (state?.tail || []).join('\n');
  $('tail').scrollTop = $('tail').scrollHeight;
  const notes = [state?.message, ...(state?.warnings || [])].filter(Boolean);
  if (notes.length) $('hint').textContent = notes.join(' ');
};

const init = async () => {
  const tab = await activeTab();
  let found = null;
  if (tab && /^https:\/\/github\.com\//.test(tab.url || '')) {
    try { found = await chrome.tabs.sendMessage(tab.id, { type: 'detect' }); } catch { found = null; }
  }

  if (found?.repo) {
    $('repo').textContent = found.repo;
    $('branch').textContent = found.branch || 'default branch';
    $('branch-input').value = found.branch || '';
    $('go').disabled = false;
    $('hint').textContent = found.branch
      ? 'Edit the branch above to check out another one of this repo.'
      : 'No branch on this page: the default branch (develop/main) will be checked out.';
  } else {
    $('hint').textContent = 'Open a GitHub repository, pull request or branch page to detect what to check out.';
  }

  const port = chrome.runtime.connect({ name: 'mmco' });
  port.onMessage.addListener((message) => {
    switch (message.type) {
      case 'run':
        if (found?.repo && (message.repo || '').toLowerCase() === found.repo.toLowerCase()) render(message.state);
        break;
      case 'host-error':
        $('error').textContent = `mmco.app host unreachable: ${message.message} `
          + `This extension's id is ${message.extensionId}. Run ./install.sh --extension-id ${message.extensionId} in ~/tools/mmco, then reload the extension.`;
        break;
      case 'checkout-fallback':
        openUrl(tab, checkoutUrl(message.repo, message.branch));
        break;
      case 'open-log-fallback':
        openUrl(tab, 'mmco://log');
        break;
      default:
        break;
    }
  });
  if (found?.repo) port.postMessage({ type: 'status', repo: found.repo });

  $('go').addEventListener('click', () => {
    if (!found?.repo) return;
    const branch = $('branch-input').value.trim();
    $('branch').textContent = branch || 'default branch';
    render({ status: 'running', phase: 'start', branch });
    port.postMessage({ type: 'checkout', repo: found.repo, branch });
  });
  $('stop').addEventListener('click', () => {
    if (!found?.repo) return;
    port.postMessage({ type: 'stop', repo: found.repo });
  });
  $('branch-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('go').click(); });
  $('settings').addEventListener('click', async () => { await openUrl(tab, 'mmco://settings'); window.close(); });
  $('config').addEventListener('click', async () => { await openUrl(tab, 'mmco://config'); window.close(); });
  $('log').addEventListener('click', () => { port.postMessage({ type: 'open-log', repo: found?.repo || '' }); });
};

initSlackTemplate();
init();
