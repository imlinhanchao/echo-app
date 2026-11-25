(function () {
  'use strict';

  var REPO = 'imlinhanchao/ebook-api';
  var RELEASES_PAGE = 'https://github.com/' + REPO + '/releases';
  var LATEST_PAGE = RELEASES_PAGE + '/latest';
  var API_LATEST = 'https://api.github.com/repos/' + REPO + '/releases/latest';
  var API_LIST = 'https://api.github.com/repos/' + REPO + '/releases?per_page=10';
  var MIRROR_PREFIX = 'https://ghfast.top/';
  var CACHE_KEY = 'ebook-api-latest-release-v1';
  var CACHE_TTL_MS = 5 * 60 * 1000;

  function formatBytes(bytes) {
    if (typeof bytes !== 'number' || !isFinite(bytes) || bytes <= 0) {
      return '';
    }
    var mb = bytes / (1024 * 1024);
    if (mb >= 1024) {
      return (mb / 1024).toFixed(2) + ' GB';
    }
    if (mb >= 1) {
      return mb.toFixed(1) + ' MB';
    }
    return Math.max(1, Math.round(bytes / 1024)) + ' KB';
  }

  function formatDate(isoString) {
    if (!isoString || typeof isoString !== 'string') return '';
    var d = new Date(isoString);
    if (isNaN(d.getTime())) return '';
    var y = d.getFullYear();
    var m = String(d.getMonth() + 1).padStart(2, '0');
    var day = String(d.getDate()).padStart(2, '0');
    return y + '-' + m + '-' + day;
  }

  function matchEbookApiAssets(assets) {
    var list = Array.isArray(assets) ? assets : [];

    function pick(patterns) {
      for (var i = 0; i < patterns.length; i++) {
        var re = patterns[i];
        for (var j = 0; j < list.length; j++) {
          var item = list[j];
          if (!item || !item.name || !item.browser_download_url) continue;
          if (re.test(item.name)) return item;
        }
      }
      return null;
    }

    return {
      linuxAmd64: pick([/linux[_-]amd64\.tar\.gz$/i]),
      linuxArm64: pick([/linux[_-]arm64\.tar\.gz$/i]),
      darwinArm64: pick([/darwin[_-]arm64\.tar\.gz$/i]),
      darwinAmd64: pick([/darwin[_-]amd64\.tar\.gz$/i]),
      windowsAmd64: pick([/windows[_-]amd64\.zip$/i]),
      checksums: pick([/^checksums\.txt$/i, /checksums.*\.txt$/i, /sha256.*\.txt$/i])
    };
  }

  function resolveDownloadUrl(rawUrl, useMirror) {
    if (!rawUrl || typeof rawUrl !== 'string') {
      return RELEASES_PAGE;
    }
    if (
      useMirror &&
      rawUrl.indexOf(MIRROR_PREFIX) !== 0 &&
      rawUrl.indexOf('https://github.com/') === 0 &&
      rawUrl.indexOf('/releases/download/') !== -1
    ) {
      return MIRROR_PREFIX + rawUrl;
    }
    return rawUrl;
  }

  function bytesToHex(bytes) {
    if (!bytes || typeof bytes.length !== 'number') return '';
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      out += ('0' + (bytes[i] & 255).toString(16)).slice(-2);
    }
    return out;
  }

  function generateHexKey(byteLen) {
    var len = typeof byteLen === 'number' && byteLen > 0 ? Math.floor(byteLen) : 32;
    var buf = new Uint8Array(len);
    var cryptoObj = typeof globalThis !== 'undefined' ? globalThis.crypto : null;
    if (cryptoObj && typeof cryptoObj.getRandomValues === 'function') {
      cryptoObj.getRandomValues(buf);
    } else if (typeof require === 'function') {
      var nodeCrypto = require('crypto');
      var randBuf = nodeCrypto.randomBytes(len);
      for (var i = 0; i < len; i++) {
        buf[i] = randBuf[i];
      }
    } else {
      for (var j = 0; j < len; j++) {
        buf[j] = Math.floor(Math.random() * 256);
      }
    }
    return bytesToHex(buf);
  }

  function sanitizeLineValue(raw) {
    if (raw === null || raw === undefined) return '';
    return String(raw).replace(/[\r\n]/g, '').trim();
  }

  function buildEnvConfig(opts) {
    var cfg = opts || {};
    var host = cfg.mode === 'proxy' ? '127.0.0.1' : '0.0.0.0';
    var parsedPort = parseInt(sanitizeLineValue(cfg.port), 10);
    var portStr =
      !isNaN(parsedPort) && parsedPort >= 1 && parsedPort <= 65535
        ? String(parsedPort)
        : '8091';
    var apiKey = sanitizeLineValue(cfg.apiKey);
    var secret = sanitizeLineValue(cfg.secret);

    var lines = [
      'EBOOK_ADDR=' + host + ':' + portStr,
      'EBOOK_DATA_DIR=data'
    ];
    if (apiKey) {
      lines.push('EBOOK_API_KEY=' + apiKey);
    }
    if (secret) {
      lines.push('EBOOK_SECRET=' + secret);
    } else {
      lines.push('# 留空则首次启动自动生成并持久化到 data/secret.key');
      lines.push('# EBOOK_SECRET=');
    }
    lines.push('EBOOK_ALLOW_PLAIN_CRED_HEADERS=false');
    if (cfg.publicDownload) {
      lines.push('EBOOK_PUBLIC_DOWNLOAD=true');
    }
    lines.push(
      'ZLIB_DOMAINS=https://z-lib.gd,https://z-lib.gl,https://z-library.ec,https://zlib.bz'
    );
    return lines.join('\n');
  }

  function readCachedRelease(allowStale) {
    try {
      var raw = sessionStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      var parsed = JSON.parse(raw);
      if (!parsed || typeof parsed.fetchedAt !== 'number') return null;
      if (!allowStale && Date.now() - parsed.fetchedAt > CACHE_TTL_MS) {
        return null;
      }
      return parsed;
    } catch (_) {
      return null;
    }
  }

  function writeCachedRelease(release) {
    try {
      sessionStorage.setItem(
        CACHE_KEY,
        JSON.stringify({ fetchedAt: Date.now(), release: release })
      );
    } catch (_) {}
  }

  async function fetchLatestRelease() {
    var cached = readCachedRelease(false);
    if (cached) {
      return { release: cached.release, fromCache: true, error: false };
    }

    var headers = { Accept: 'application/vnd.github+json' };
    try {
      var res = await fetch(API_LATEST, { headers: headers });
      if (res.ok) {
        var release = await res.json();
        writeCachedRelease(release);
        return { release: release, fromCache: false, error: false };
      }

      if (res.status === 404) {
        var listRes = await fetch(API_LIST, { headers: headers });
        if (listRes.ok) {
          var list = await listRes.json();
          var picked = Array.isArray(list)
            ? list.find(function (item) {
                return item && !item.draft;
              }) || null
            : null;
          writeCachedRelease(picked);
          return { release: picked, fromCache: false, error: false };
        }
        res = listRes;
      }

      var stale = readCachedRelease(true);
      if (stale && stale.release) {
        return { release: stale.release, fromCache: true, error: false };
      }
      return { release: null, fromCache: false, error: true, status: res.status };
    } catch (_) {
      var fallback = readCachedRelease(true);
      if (fallback && fallback.release) {
        return { release: fallback.release, fromCache: true, error: false };
      }
      return { release: null, fromCache: false, error: true, status: 0 };
    }
  }

  function initThemeToggle() {
    var toggle = document.getElementById('theme-toggle');
    var themeMeta = document.querySelector('meta[name="theme-color"]');

    function applyTheme(theme) {
      document.documentElement.dataset.theme = theme;
      if (themeMeta) {
        themeMeta.setAttribute('content', theme === 'light' ? '#F8F5F0' : '#0D0E10');
      }
    }

    applyTheme(document.documentElement.dataset.theme === 'light' ? 'light' : 'dark');

    if (toggle) {
      toggle.addEventListener('click', function () {
        var next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
        applyTheme(next);
        try {
          localStorage.setItem('echo-site-theme', next);
        } catch (_) {}
      });
    }
  }

  function initDeployTabs() {
    var tablist = document.querySelector('[role="tablist"]');
    if (!tablist) return;
    var tabs = Array.prototype.slice.call(tablist.querySelectorAll('[role="tab"]'));
    if (!tabs.length) return;

    function activateTab(nextTab, moveFocus) {
      for (var i = 0; i < tabs.length; i++) {
        var tab = tabs[i];
        var selected = tab === nextTab;
        tab.setAttribute('aria-selected', selected ? 'true' : 'false');
        tab.setAttribute('tabindex', selected ? '0' : '-1');
        var panelId = tab.getAttribute('aria-controls');
        if (panelId) {
          var panel = document.getElementById(panelId);
          if (panel) {
            panel.hidden = !selected;
          }
        }
      }
      if (moveFocus) {
        nextTab.focus();
      }
    }

    for (var i = 0; i < tabs.length; i++) {
      (function (index) {
        var tab = tabs[index];
        tab.addEventListener('click', function () {
          activateTab(tab, false);
        });
        tab.addEventListener('keydown', function (event) {
          var targetIndex = index;
          if (event.key === 'ArrowRight') {
            targetIndex = (index + 1) % tabs.length;
          } else if (event.key === 'ArrowLeft') {
            targetIndex = (index - 1 + tabs.length) % tabs.length;
          } else if (event.key === 'Home') {
            targetIndex = 0;
          } else if (event.key === 'End') {
            targetIndex = tabs.length - 1;
          } else {
            return;
          }
          event.preventDefault();
          activateTab(tabs[targetIndex], true);
        });
      })(i);
    }

    var triggers = document.querySelectorAll('[data-select-tab]');
    for (var t = 0; t < triggers.length; t++) {
      (function (trigger) {
        trigger.addEventListener('click', function () {
          var targetId = trigger.getAttribute('data-select-tab');
          var targetTab = targetId ? document.getElementById(targetId) : null;
          if (targetTab) {
            activateTab(targetTab, false);
          }
        });
      })(triggers[t]);
    }
  }

  function initEnvBuilder() {
    var modeRadios = document.querySelectorAll('input[name="env-mode"]');
    var portInput = document.getElementById('env-port');
    var apiKeyInput = document.getElementById('env-api-key');
    var secretInput = document.getElementById('env-secret');
    var publicCheckbox = document.getElementById('env-public-download');
    var genApiBtn = document.getElementById('gen-api-key');
    var genSecretBtn = document.getElementById('gen-secret');
    var outputEl = document.getElementById('generated-env-code');

    if (!outputEl) return;

    function currentMode() {
      for (var i = 0; i < modeRadios.length; i++) {
        if (modeRadios[i].checked) return modeRadios[i].value;
      }
      return 'lan';
    }

    function render() {
      outputEl.textContent = buildEnvConfig({
        mode: currentMode(),
        port: portInput ? portInput.value : '8091',
        apiKey: apiKeyInput ? apiKeyInput.value : '',
        secret: secretInput ? secretInput.value : '',
        publicDownload: publicCheckbox ? Boolean(publicCheckbox.checked) : false
      });
    }

    for (var i = 0; i < modeRadios.length; i++) {
      modeRadios[i].addEventListener('change', render);
    }
    if (portInput) portInput.addEventListener('input', render);
    if (apiKeyInput) apiKeyInput.addEventListener('input', render);
    if (secretInput) secretInput.addEventListener('input', render);
    if (publicCheckbox) publicCheckbox.addEventListener('change', render);

    if (genApiBtn && apiKeyInput) {
      genApiBtn.addEventListener('click', function () {
        apiKeyInput.value = generateHexKey(24);
        render();
      });
    }
    if (genSecretBtn && secretInput) {
      genSecretBtn.addEventListener('click', function () {
        secretInput.value = generateHexKey(32);
        render();
      });
    }

    render();
  }

  function copyText(text) {
    if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      try {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.position = 'fixed';
        ta.style.left = '-9999px';
        document.body.appendChild(ta);
        ta.select();
        var ok = document.execCommand('copy');
        document.body.removeChild(ta);
        if (ok) resolve();
        else reject(new Error('copy failed'));
      } catch (err) {
        reject(err);
      }
    });
  }

  function initCopyButtons() {
    var buttons = document.querySelectorAll('.copy-btn');
    for (var i = 0; i < buttons.length; i++) {
      (function (btn) {
        var resetTimer = null;
        var initialLabel = btn.textContent || '复制';
        btn.addEventListener('click', function () {
          var block = btn.closest('.code-block');
          var code = block ? block.querySelector('pre code') : null;
          if (!code) return;
          var text = code.textContent || '';
          copyText(text)
            .then(function () {
              btn.textContent = '已复制';
              btn.classList.add('is-copied');
              if (resetTimer) clearTimeout(resetTimer);
              resetTimer = setTimeout(function () {
                btn.textContent = initialLabel;
                btn.classList.remove('is-copied');
              }, 1600);
            })
            .catch(function () {
              btn.textContent = '请手动复制';
              if (resetTimer) clearTimeout(resetTimer);
              resetTimer = setTimeout(function () {
                btn.textContent = initialLabel;
              }, 1600);
            });
        });
      })(buttons[i]);
    }
  }

  function bootBrowser() {
    initThemeToggle();
    initDeployTabs();
    initEnvBuilder();
    initCopyButtons();

    var useMirror = false;
    try {
      useMirror = localStorage.getItem('echo-site-mirror') === '1';
    } catch (_) {}

    var currentRelease = null;
    var lastStatusError = false;

    var mirrorToggle = document.getElementById('mirror-toggle');
    var mirrorLabel = document.getElementById('mirror-label');

    function updateMirrorButton() {
      if (!mirrorToggle || !mirrorLabel) return;
      mirrorToggle.setAttribute('aria-pressed', useMirror ? 'true' : 'false');
      mirrorLabel.textContent = useMirror ? '线路：ghfast.top 国内镜像' : '线路：GitHub 直连';
    }

    function applyReleaseUI() {
      var heroBadge = document.getElementById('ebook-api-version-badge');
      var relTag = document.getElementById('ebook-api-release-version');
      var relDate = document.getElementById('ebook-api-release-date');
      var relNoteBadge = document.getElementById('ebook-api-release-tag-note');
      var checksumsEl = document.getElementById('ebook-api-checksums-link');

      if (!currentRelease) {
        if (heroBadge) {
          heroBadge.textContent = lastStatusError
            ? 'GitHub Release 查询受限 · 请前往 Releases 查看'
            : 'Ebook API · 准备就绪';
        }
        if (relTag) relTag.textContent = 'Releases';
        if (relDate) {
          relDate.textContent = lastStatusError
            ? 'GitHub API 访问受限，以下链接已直指 Releases 页面'
            : '暂无预编译 Release 时可使用 Docker / NAS 构建';
        }
        if (relNoteBadge) relNoteBadge.hidden = true;
        if (checksumsEl) checksumsEl.hidden = true;

        var fallbackLinks = document.querySelectorAll('[data-ebook-download]');
        for (var i = 0; i < fallbackLinks.length; i++) {
          fallbackLinks[i].href = RELEASES_PAGE;
        }
        return;
      }

      var tag = currentRelease.tag_name || currentRelease.name || 'latest';
      var dateText = formatDate(currentRelease.published_at || currentRelease.created_at);
      var assets = matchEbookApiAssets(currentRelease.assets);
      var releaseHtmlUrl = currentRelease.html_url || LATEST_PAGE;

      if (heroBadge) {
        heroBadge.textContent =
          'Ebook API ' +
          tag +
          (currentRelease.prerelease ? ' (Pre-release)' : '') +
          (dateText ? ' · ' + dateText : '');
      }
      if (relTag) relTag.textContent = tag;
      if (relDate) relDate.textContent = dateText ? '发布于 ' + dateText : 'GitHub 最新版本';
      if (relNoteBadge) {
        if (currentRelease.prerelease) {
          relNoteBadge.textContent = 'Pre-release 预发布';
          relNoteBadge.hidden = false;
        } else {
          relNoteBadge.hidden = true;
        }
      }

      if (checksumsEl) {
        if (assets.checksums) {
          checksumsEl.href = resolveDownloadUrl(assets.checksums.browser_download_url, useMirror);
          checksumsEl.hidden = false;
        } else {
          checksumsEl.hidden = true;
        }
      }

      var cmdTags = document.querySelectorAll('[data-ebook-cmd-tag]');
      for (var c = 0; c < cmdTags.length; c++) {
        cmdTags[c].textContent = tag;
      }

      var keys = ['linuxAmd64', 'linuxArm64', 'darwinArm64', 'darwinAmd64', 'windowsAmd64'];
      for (var k = 0; k < keys.length; k++) {
        var key = keys[k];
        var asset = assets[key];
        var link = document.querySelector('[data-ebook-download="' + key + '"]');
        var sizeEl = document.querySelector('[data-ebook-size="' + key + '"]');
        if (link) {
          link.href = asset
            ? resolveDownloadUrl(asset.browser_download_url, useMirror)
            : releaseHtmlUrl;
        }
        if (sizeEl && asset) {
          var sizeStr = formatBytes(asset.size);
          if (sizeStr) {
            sizeEl.textContent = sizeStr;
          }
        }
      }
    }

    updateMirrorButton();

    if (mirrorToggle) {
      mirrorToggle.addEventListener('click', function () {
        useMirror = !useMirror;
        try {
          localStorage.setItem('echo-site-mirror', useMirror ? '1' : '0');
        } catch (_) {}
        updateMirrorButton();
        applyReleaseUI();
      });
    }

    fetchLatestRelease().then(function (result) {
      currentRelease = result.release;
      lastStatusError = Boolean(result.error);
      applyReleaseUI();
    });
  }

  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', bootBrowser);
    } else {
      bootBrowser();
    }
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
      REPO: REPO,
      RELEASES_PAGE: RELEASES_PAGE,
      formatBytes: formatBytes,
      formatDate: formatDate,
      matchEbookApiAssets: matchEbookApiAssets,
      resolveDownloadUrl: resolveDownloadUrl,
      bytesToHex: bytesToHex,
      generateHexKey: generateHexKey,
      buildEnvConfig: buildEnvConfig
    };
  }
})();
