// Detects the repo + branch on GitHub pages, injects a "Checkout locally" button next to the
// branch, and answers the popup's detect/open messages. Everything ends in an mmco:// URL that
// the macOS app handles.
(() => {
  const BUTTON_CLASS = 'mmco-button';

  const checkoutUrl = (repo, branch) =>
    `mmco://checkout?repo=${encodeURIComponent(repo)}&branch=${encodeURIComponent(branch)}`;

  // Navigating an anchor to a custom scheme is what triggers Chrome's "Open mmco?" prompt,
  // with its "Always allow" checkbox. window.open and location.href are less reliable for it.
  const openUrl = (url) => {
    const a = document.createElement('a');
    a.href = url;
    a.style.display = 'none';
    document.body.appendChild(a);
    a.click();
    a.remove();
  };

  const repoFromPath = () => {
    const m = location.pathname.match(/^\/([^/]+)\/([^/]+)/);
    if (!m) return null;
    const owner = m[1];
    const repo = m[2];
    if (['orgs', 'settings', 'marketplace', 'explore', 'notifications', 'topics', 'search'].includes(owner)) return null;
    return `${owner}/${repo}`;
  };

  const decodeBranch = (raw) => {
    try { return decodeURIComponent(raw); } catch { return raw; }
  };

  // PR header, current React layout: the head branch is the BranchName link whose wrapper holds
  // the "copy head branch name" icon button as a direct child. The base branch sits one level up,
  // in the container that wraps everything, so a descendant match would pick it. Classic layout:
  // .head-ref.
  const prHead = () => {
    const container = document.querySelector('[class*="PullRequestHeaderBranches"]');
    if (container) {
      for (const link of container.querySelectorAll('a[data-component="BranchName"]')) {
        if (link.parentElement.querySelector(':scope > button .octicon-copy')) {
          return { branch: link.textContent.trim(), anchor: link.parentElement };
        }
      }
    }
    const classic = document.querySelector('.head-ref');
    if (classic) {
      const text = classic.textContent.trim();
      return { branch: text.includes(':') ? text.split(':').pop() : text, anchor: classic };
    }
    return null;
  };

  const detect = () => {
    const repo = repoFromPath();
    if (!repo) return null;
    const path = location.pathname.replace(/^\/[^/]+\/[^/]+/, '');

    if (/^\/pull\/\d+/.test(path)) {
      const head = prHead();
      return head ? { repo, branch: head.branch, kind: 'pull', anchor: head.anchor } : { repo, branch: '', kind: 'pull' };
    }
    const tree = path.match(/^\/(?:tree|blob|commits)\/([^?#]+)/);
    if (tree) {
      // A branch may contain slashes (feat/MM-1) and a file path follows on blob pages; the
      // branch picker button carries the exact ref.
      const picker = document.querySelector('[data-hotkey="w"] span, button#branch-picker-repos-header-ref-selector span[class*="Text"]');
      const branch = picker?.textContent.trim() || decodeBranch(tree[1]).split('/').slice(0, 2).join('/');
      return { repo, branch, kind: 'tree' };
    }
    const compare = path.match(/^\/compare\/(?:[^.]+\.\.\.)?([^?#]+)/);
    if (compare) return { repo, branch: decodeBranch(compare[1]), kind: 'compare' };

    return { repo, branch: '', kind: 'repo' };
  };

  const makeButton = (repo, branch, compact) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = BUTTON_CLASS + (compact ? ' mmco-button--compact' : '');
    button.title = `mmco: check out ${branch} in your local ${repo}`;
    button.textContent = compact ? 'mmco' : 'Checkout locally';
    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      openUrl(checkoutUrl(repo, branch));
    });
    return button;
  };

  const injectPullRequest = () => {
    const found = detect();
    if (!found || found.kind !== 'pull' || !found.anchor || !found.branch) return;
    if (found.anchor.querySelector(`.${BUTTON_CLASS}`)) return;
    found.anchor.appendChild(makeButton(found.repo, found.branch, false));
  };

  const injectBranchList = () => {
    const repo = repoFromPath();
    if (!repo || !/^\/[^/]+\/[^/]+\/branches/.test(location.pathname)) return;
    for (const link of document.querySelectorAll('a[href*="/tree/"]')) {
      const row = link.closest('tr, li, [class*="BranchRow"]');
      if (!row || row.querySelector(`.${BUTTON_CLASS}`)) continue;
      const m = link.getAttribute('href').match(/\/tree\/(.+)$/);
      if (!m) continue;
      const branch = decodeBranch(m[1]);
      if (link.textContent.trim() !== branch) continue;
      link.insertAdjacentElement('afterend', makeButton(repo, branch, true));
    }
  };

  const inject = () => {
    injectPullRequest();
    injectBranchList();
  };

  globalThis.chrome?.runtime?.onMessage?.addListener((message, _sender, sendResponse) => {
    if (message?.type === 'detect') {
      const found = detect();
      sendResponse(found ? { repo: found.repo, branch: found.branch, kind: found.kind } : null);
    } else if (message?.type === 'open' && typeof message.url === 'string' && message.url.startsWith('mmco://')) {
      openUrl(message.url);
      sendResponse(true);
    }
    return false;
  });

  // GitHub is a soft-navigating SPA; re-inject on DOM changes, cheaply debounced.
  let scheduled = 0;
  const observer = new MutationObserver(() => {
    if (scheduled) return;
    scheduled = window.setTimeout(() => { scheduled = 0; inject(); }, 250);
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  inject();
})();
