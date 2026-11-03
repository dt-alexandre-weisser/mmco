// Detects the repo + branch on GitHub pages, injects a "Checkout locally" button next to the
// branch, and answers the popup's detect/open messages. A click goes to the background service
// worker, which talks to mmco.app over native messaging; the button then mirrors the run's state
// (spinner while it runs, then checked out / failed). Without the host it falls back to an
// mmco:// URL.
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

  // ---------------------------------------------------------------- background port

  let port = null;
  const buttons = new Set();

  const connect = () => {
    if (port) return port;
    try {
      port = chrome.runtime.connect({ name: 'mmco' });
    } catch {
      return null; // extension reloaded: this page's context is gone
    }
    port.onMessage.addListener((message) => { for (const button of buttons) button.receive(message); });
    port.onDisconnect.addListener(() => { port = null; });
    return port;
  };

  const send = (message) => {
    const p = connect();
    if (!p) return false;
    try { p.postMessage(message); return true; } catch { port = null; return false; }
  };

  // ---------------------------------------------------------------- detection

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
  // the "copy head branch name" icon button as a direct child; the base branch has none. The
  // header's container class is a hashed CSS-module name that GitHub renames, so the whole page
  // is searched. The first match is the visible header, the second the hidden sticky one.
  // Classic layout: .head-ref.
  const prHead = () => {
    for (const link of document.querySelectorAll('a[data-component="BranchName"]')) {
      if (link.parentElement.querySelector(':scope > button .octicon-copy')) {
        return { branch: link.textContent.trim(), anchor: link.parentElement };
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

  // ---------------------------------------------------------------- button

  const LABELS = {
    idle: 'Checkout locally',
    running: 'Checking out…',
    post: 'Post-checkout…',
    done: 'Checked out',
    failed: 'Failed',
    stopped: 'Stopped',
  };
  const FALLBACK_SPIN_MS = 4000;

  const sameRun = (state, repo, branch) =>
    (state.repo || '').toLowerCase() === repo.toLowerCase() && (state.branch || '') === branch;

  const makeButton = (repo, branch, compact) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = BUTTON_CLASS + (compact ? ' mmco-button--compact' : '');
    button.dataset.state = 'idle';
    const icon = document.createElement('span');
    icon.className = 'mmco-icon';
    const label = document.createElement('span');
    label.className = 'mmco-label';
    button.append(icon, label);

    let fallbackTimer = 0;
    const set = (state, text, title) => {
      button.dataset.state = state;
      label.textContent = compact ? 'mmco' : text;
      button.title = title || `mmco: check out ${branch} in your local ${repo}`;
    };
    set('idle', LABELS.idle);

    const entry = {
      button,
      receive(message) {
        if (message.type === 'run' && message.state) {
          const state = message.state;
          if (!sameRun(state, repo, branch)) return;
          window.clearTimeout(fallbackTimer);
          const detail = [state.phase && `phase: ${state.phase}`, state.message, ...(state.warnings || [])].filter(Boolean).join('\n');
          switch (state.status) {
            case 'running':
              set('running', state.phase === 'post-checkout' ? LABELS.post : LABELS.running, `mmco: ${detail}`);
              break;
            case 'done':
              set('done', LABELS.done, `mmco: ${state.landed || branch} checked out in ${state.path || repo}${detail ? '\n' + detail : ''}`);
              break;
            case 'failed':
              set('failed', LABELS.failed, `mmco: ${detail || 'failed'}\nClick to retry.`);
              break;
            case 'stopped':
              set('stopped', LABELS.stopped, 'mmco: run stopped. Click to retry.');
              break;
            default:
              set('idle', LABELS.idle);
          }
        } else if (message.type === 'checkout-fallback' && sameRun(message, repo, branch)) {
          openUrl(checkoutUrl(repo, branch));
          set('running', LABELS.running, 'mmco: handed to mmco.app (no progress without the native host)');
          window.clearTimeout(fallbackTimer);
          fallbackTimer = window.setTimeout(() => set('idle', LABELS.idle), FALLBACK_SPIN_MS);
        }
      },
    };
    buttons.add(entry);

    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (button.dataset.state === 'running') return;
      set('running', LABELS.running, 'mmco: starting…');
      if (!send({ type: 'checkout', repo, branch })) {
        openUrl(checkoutUrl(repo, branch));
        fallbackTimer = window.setTimeout(() => set('idle', LABELS.idle), FALLBACK_SPIN_MS);
      }
    });
    return button;
  };

  // "Slack it": copies the message set in the popup (default ":approved_stamp: <url> plz") to the
  // clipboard, to paste in Slack. {url} in the message is replaced by the pull request link, and
  // each {rdm} by its own random emoji, drawn again on every copy.
  const SLACK_RESET_MS = 3000;
  const SLACK_TEMPLATE_DEFAULT = ':approved_stamp: {url} plz';
  const SLACK_EMOJIS = [
    '🙏', '🚀', '✨', '🔥', '👀', '🎉', '💪', '🙌', '⚡', '🌟', '🍀', '🦄', '🐙', '🦊', '🐢', '🍕',
    '🍩', '☕', '🌈', '🎯', '🧠', '💡', '🛠️', '📦', '🔍', '🥳', '😇', '🤞', '👍', '💯', '🫶', '🌻',
  ];
  const randomEmoji = () => SLACK_EMOJIS[Math.floor(Math.random() * SLACK_EMOJIS.length)];

  const slackMessage = async (url) => {
    let template = '';
    try { ({ slackTemplate: template } = await chrome.storage.sync.get('slackTemplate')); } catch { /* extension reloaded */ }
    return (template || SLACK_TEMPLATE_DEFAULT).replaceAll('{url}', url).replaceAll('{rdm}', randomEmoji);
  };

  const makeSlackButton = (url) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `${BUTTON_CLASS} mmco-button--slack`;
    const icon = document.createElement('span');
    icon.className = 'mmco-icon';
    const label = document.createElement('span');
    label.className = 'mmco-label';
    button.append(icon, label);

    let resetTimer = 0;
    const set = (state, labelText, title) => {
      button.dataset.state = state;
      label.textContent = labelText;
      button.title = title;
    };
    const idle = () => set('idle', 'Slack it', 'mmco: copy the Slack message for this pull request (edit it in the mmco popup)');
    idle();

    button.addEventListener('click', async (event) => {
      event.preventDefault();
      event.stopPropagation();
      window.clearTimeout(resetTimer);
      try {
        const text = await slackMessage(url);
        await navigator.clipboard.writeText(text);
        set('done', 'Copied', `mmco: "${text}" copied`);
      } catch (error) {
        set('failed', 'Failed', `mmco: clipboard refused: ${error?.message || error}`);
      }
      resetTimer = window.setTimeout(idle, SLACK_RESET_MS);
    });
    return button;
  };

  const prUrl = () => {
    const m = location.pathname.match(/^\/[^/]+\/[^/]+\/pull\/\d+/);
    return m ? `${location.origin}${m[0]}` : null;
  };

  // Buttons removed by GitHub's re-renders stay in `buttons` until the next sweep.
  const sweep = () => { for (const entry of buttons) if (!entry.button?.isConnected) buttons.delete(entry); };

  const injectPullRequest = () => {
    const found = detect();
    if (!found || found.kind !== 'pull' || !found.anchor || !found.branch) return false;
    if (found.anchor.querySelector(`.${BUTTON_CLASS}`)) return false;
    found.anchor.appendChild(makeButton(found.repo, found.branch, false));
    const url = prUrl();
    if (url) found.anchor.appendChild(makeSlackButton(url));
    return found.repo;
  };

  const injectBranchList = () => {
    const repo = repoFromPath();
    if (!repo || !/^\/[^/]+\/[^/]+\/branches/.test(location.pathname)) return false;
    let added = false;
    for (const link of document.querySelectorAll('a[href*="/tree/"]')) {
      const row = link.closest('tr, li, [class*="BranchRow"]');
      if (!row || row.querySelector(`.${BUTTON_CLASS}`)) continue;
      const m = link.getAttribute('href').match(/\/tree\/(.+)$/);
      if (!m) continue;
      const branch = decodeBranch(m[1]);
      if (link.textContent.trim() !== branch) continue;
      link.insertAdjacentElement('afterend', makeButton(repo, branch, true));
      added = true;
    }
    return added ? repo : false;
  };

  const inject = () => {
    const repo = injectPullRequest() || injectBranchList();
    if (repo) send({ type: 'status', repo });
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
    scheduled = window.setTimeout(() => { scheduled = 0; sweep(); inject(); }, 250);
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  inject();
})();
