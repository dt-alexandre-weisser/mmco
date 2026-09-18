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

  $('go').addEventListener('click', async () => {
    if (!found?.repo) return;
    await openUrl(tab, checkoutUrl(found.repo, $('branch-input').value.trim()));
    window.close();
  });
  $('branch-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('go').click(); });
  $('settings').addEventListener('click', async () => { await openUrl(tab, 'mmco://settings'); window.close(); });
  $('config').addEventListener('click', async () => { await openUrl(tab, 'mmco://config'); window.close(); });
};

init();
