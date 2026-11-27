(function () {
  'use strict';

  var REPO = 'imlinhanchao/echo-app';
  var RELEASES_PAGE = 'https://github.com/' + REPO + '/releases';
  var LATEST_PAGE = RELEASES_PAGE + '/latest';
  var API_LATEST = 'https://api.github.com/repos/' + REPO + '/releases/latest';
  var API_LIST = 'https://api.github.com/repos/' + REPO + '/releases?per_page=10';
  var MIRROR_PREFIX = 'https://ghfast.top/';
  var CACHE_KEY = 'echo-latest-release-v1';
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

  function detectPlatform(uaInput, platformHintInput, maxTouchPoints) {
    var ua = (uaInput || '').toLowerCase();
    var hint = (platformHintInput || '').toLowerCase();
    var touches = typeof maxTouchPoints === 'number' ? maxTouchPoints : 0;

    if (ua.indexOf('android') !== -1) {
      return 'android';
    }
    if (/iphone|ipad|ipod/.test(ua) || (hint.indexOf('mac') !== -1 && touches > 1)) {
      return 'ios';
    }
    if (ua.indexOf('windows') !== -1 || hint.indexOf('win') !== -1) {
      return 'windows';
    }
    if (ua.indexOf('macintosh') !== -1 || ua.indexOf('mac os') !== -1 || hint.indexOf('mac') !== -1) {
      return 'macos';
    }
    if (ua.indexOf('linux') !== -1 || ua.indexOf('x11') !== -1 || hint.indexOf('linux') !== -1) {
      return 'linux';
    }
    return 'unknown';
  }

  function matchReleaseAssets(assets) {
    var list = Array.isArray(assets) ? assets : [];

    function pick(patterns, exclude) {
      for (var i = 0; i < patterns.length; i++) {
        var re = patterns[i];
        for (var j = 0; j < list.length; j++) {
          var item = list[j];
          if (!item || !item.name || !item.browser_download_url) continue;
          if (exclude && exclude === item) continue;
          if (re.test(item.name)) return item;
        }
      }
      return null;
    }

    var androidArm64 = pick([/android.*arm64.*\.apk$/i, /arm64.*\.apk$/i]);
    var androidUniversal = pick(
      [/android.*universal.*\.apk$/i, /universal.*\.apk$/i, /\.apk$/i],
      androidArm64
    );
    var macos = pick([/macos.*\.dmg$/i, /\.dmg$/i, /macos.*\.zip$/i]);
    var windows = pick([/windows.*\.zip$/i, /win.*\.zip$/i, /\.exe$/i, /\.msix$/i]);
    var linux = pick([/linux.*\.tar\.gz$/i, /\.AppImage$/i, /linux.*\.(deb|rpm)$/i]);
    var checksums = pick([/^checksums\.txt$/i, /checksums.*\.txt$/i, /sha256.*\.txt$/i]);

    return {
      androidArm64: androidArm64,
      androidUniversal: androidUniversal,
      macos: macos,
      windows: windows,
      linux: linux,
      checksums: checksums
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

  function renderReleaseNotes(container, bodyText, releaseUrl) {
    if (!container) return;
    while (container.firstChild) {
      container.removeChild(container.firstChild);
    }

    var raw = typeof bodyText === 'string' ? bodyText.trim() : '';
    if (!raw) {
      var empty = document.createElement('p');
      empty.textContent = '当前版本暂无额外说明，可在 GitHub Release 页面查看完整提交记录。';
      container.appendChild(empty);
      if (releaseUrl) {
        var link = document.createElement('a');
        link.href = releaseUrl;
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
        link.className = 'all-releases-link';
        link.textContent = '在 GitHub 查看此版本详情 →';
        container.appendChild(link);
      }
      return;
    }

    var lines = raw.split(/\r?\n/);
    var activeList = null;

    function flushList() {
      if (activeList) {
        container.appendChild(activeList);
        activeList = null;
      }
    }

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (!line) {
        flushList();
        continue;
      }
      if (/^#{1,4}\s+/.test(line)) {
        flushList();
        var h4 = document.createElement('h4');
        h4.textContent = line.replace(/^#{1,4}\s+/, '').trim();
        container.appendChild(h4);
        continue;
      }
      if (/^[-*+]\s+/.test(line)) {
        if (!activeList) {
          activeList = document.createElement('ul');
        }
        var li = document.createElement('li');
        li.textContent = line.replace(/^[-*+]\s+/, '').trim();
        activeList.appendChild(li);
        continue;
      }
      flushList();
      var p = document.createElement('p');
      p.textContent = line;
      container.appendChild(p);
    }
    flushList();
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

  function initTabLists() {
    var tablists = document.querySelectorAll('[role="tablist"]');
    for (var t = 0; t < tablists.length; t++) {
      (function (tablist) {
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
      })(tablists[t]);
    }
  }

  function initReaderMockup() {
    var mockup = document.getElementById('reader-mockup');
    var pairs = Array.prototype.slice.call(document.querySelectorAll('.cue-pair'));
    var cues = pairs.length
      ? pairs
      : Array.prototype.slice.call(document.querySelectorAll('.cue-sentence'));
    var playBtn = document.getElementById('mockup-play-btn');
    var bilingualBtn = document.getElementById('mockup-bilingual-btn');
    var speedBtn = document.getElementById('mockup-speed-btn');
    var cueLabel = document.getElementById('mockup-cue-label');
    var progressFill = document.getElementById('mockup-progress-fill');

    if (!cues.length || !playBtn || !speedBtn) return;

    var speeds = [1.0, 1.25, 1.5, 1.75];
    var speedIndex = 0;
    var activeCue = 0;
    var reducedMotion =
      typeof window.matchMedia === 'function' &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var isPlaying = !reducedMotion;
    var isBilingual = false;
    var timer = null;

    function updateMockupView() {
      for (var i = 0; i < cues.length; i++) {
        var active = i === activeCue;
        cues[i].classList.toggle('is-active', active);
        var sentenceEl = cues[i].classList.contains('cue-sentence')
          ? cues[i]
          : cues[i].querySelector('.cue-sentence');
        if (sentenceEl && sentenceEl !== cues[i]) {
          sentenceEl.classList.toggle('is-active', active);
        }
      }
      if (mockup) {
        mockup.classList.toggle('is-bilingual', isBilingual);
      }
      if (bilingualBtn) {
        bilingualBtn.setAttribute('aria-pressed', isBilingual ? 'true' : 'false');
      }
      playBtn.setAttribute('aria-pressed', isPlaying ? 'true' : 'false');
      if (cueLabel) {
        if (isPlaying) {
          cueLabel.textContent =
            (isBilingual ? '双语对照 · 第 ' : '边听边看 · 第 ') +
            (activeCue + 1) +
            ' / ' +
            cues.length +
            ' 句高亮';
        } else {
          cueLabel.textContent = isBilingual
            ? '双语预览 · 点击继续朗读'
            : '已暂停 · 点击继续预览';
        }
      }
      if (progressFill) {
        progressFill.style.width = (((activeCue + 1) / cues.length) * 100).toFixed(1) + '%';
      }
      speedBtn.textContent = speeds[speedIndex] + 'x';
    }

    function scheduleTick() {
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
      if (!isPlaying) return;
      var intervalMs = Math.round(3200 / speeds[speedIndex]);
      timer = setInterval(function () {
        activeCue = (activeCue + 1) % cues.length;
        updateMockupView();
      }, intervalMs);
    }

    playBtn.addEventListener('click', function () {
      isPlaying = !isPlaying;
      updateMockupView();
      scheduleTick();
    });

    if (bilingualBtn) {
      bilingualBtn.addEventListener('click', function () {
        isBilingual = !isBilingual;
        updateMockupView();
      });
    }

    speedBtn.addEventListener('click', function () {
      speedIndex = (speedIndex + 1) % speeds.length;
      updateMockupView();
      scheduleTick();
    });

    for (var i = 0; i < cues.length; i++) {
      (function (idx) {
        cues[idx].addEventListener('click', function () {
          activeCue = idx;
          updateMockupView();
          scheduleTick();
        });
      })(i);
    }

    updateMockupView();
    scheduleTick();
  }

  function bootBrowser() {
    initThemeToggle();
    initTabLists();
    initReaderMockup();

    var allReleasesLink = document.querySelector('.all-releases-link');
    if (allReleasesLink) {
      allReleasesLink.addEventListener('click', function (e) {
        e.stopPropagation();
      });
    }

    var detected = detectPlatform(
      navigator.userAgent,
      navigator.userAgentData && navigator.userAgentData.platform
        ? navigator.userAgentData.platform
        : navigator.platform,
      navigator.maxTouchPoints
    );

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

    function applyPlatformHighlight() {
      var cards = document.querySelectorAll('[data-platform-card]');
      for (var i = 0; i < cards.length; i++) {
        var card = cards[i];
        var match = card.getAttribute('data-platform-card') === detected;
        card.classList.toggle('is-recommended', match);
        var badge = card.querySelector('.platform-rec-badge');
        if (badge) {
          badge.hidden = !match;
        }
      }
    }

    function applyReleaseUI() {
      var heroBadge = document.getElementById('hero-version-badge');
      var heroCta = document.getElementById('hero-primary-cta');
      var heroCtaLabel = document.getElementById('hero-cta-label');
      var heroCtaMeta = document.getElementById('hero-cta-meta');

      var relTag = document.getElementById('release-version');
      var relDate = document.getElementById('release-date');
      var relNoteBadge = document.getElementById('release-tag-note');
      var checksumsEl = document.getElementById('checksums-link');
      var notesBody = document.getElementById('release-notes-body');

      if (!currentRelease) {
        if (heroBadge) {
          heroBadge.textContent = lastStatusError
            ? 'GitHub Release 查询受限 · 请前往 Releases 下载'
            : 'GitHub Releases · 准备就绪';
        }
        if (heroCta) {
          heroCta.href = RELEASES_PAGE;
        }
        if (heroCtaLabel) {
          heroCtaLabel.textContent =
            detected === 'ios' ? '查看全平台下载' : '前往 GitHub Releases';
        }
        if (heroCtaMeta) {
          heroCtaMeta.textContent =
            detected === 'ios'
              ? '暂不支持 iOS · 请选用桌面端或 Android 版'
              : lastStatusError
                ? '网络或 API 限流，点击直达 GitHub 发布页'
                : '当前尚无已发布版本，请先运行 GitHub Release 工作流';
        }
        if (relTag) relTag.textContent = '暂无发行版';
        if (relDate) {
          relDate.textContent = lastStatusError
            ? 'GitHub API 访问受限，以下链接已直指 Releases 页面'
            : '仓库首次发布后将自动在此展示安装包直链';
        }
        if (relNoteBadge) relNoteBadge.hidden = true;
        if (checksumsEl) checksumsEl.hidden = true;

        var fallbackLinks = document.querySelectorAll('[data-download]');
        for (var i = 0; i < fallbackLinks.length; i++) {
          fallbackLinks[i].href = RELEASES_PAGE;
        }
        renderReleaseNotes(
          notesBody,
          lastStatusError
            ? '无法连接 GitHub API 获取最新说明，请直接点击右上角「全部历史版本」查看。'
            : '尚未发布首个正式版本。触发 GitHub Actions 中的 Release 工作流后，此处将自动显示版本说明与下载直链。',
          RELEASES_PAGE
        );
        return;
      }

      var tag = currentRelease.tag_name || currentRelease.name || 'latest';
      var dateText = formatDate(currentRelease.published_at || currentRelease.created_at);
      var assets = matchReleaseAssets(currentRelease.assets);

      if (heroBadge) {
        heroBadge.textContent =
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

      var releaseHtmlUrl = currentRelease.html_url || LATEST_PAGE;

      function bindAsset(key, asset, metaKey, fallbackMeta, sizeKey, fallbackSize) {
        var link = document.querySelector('[data-download="' + key + '"]');
        var meta = metaKey ? document.querySelector('[data-meta="' + metaKey + '"]') : null;
        var sizeBadge = sizeKey ? document.querySelector('[data-size="' + sizeKey + '"]') : null;
        if (link) {
          link.href = asset
            ? resolveDownloadUrl(asset.browser_download_url, useMirror)
            : releaseHtmlUrl;
        }
        var sizeStr = asset ? formatBytes(asset.size) : '';
        if (meta) {
          if (asset) {
            meta.textContent = asset.name + (sizeStr ? ' · ' + sizeStr : '');
          } else {
            meta.textContent = fallbackMeta;
          }
        }
        if (sizeBadge) {
          sizeBadge.textContent = sizeStr || fallbackSize || '';
        }
      }

      var primaryAndroid = assets.androidArm64 || assets.androidUniversal;
      bindAsset('androidArm64', primaryAndroid, null, '', 'androidArm64', '推荐');
      bindAsset('androidUniversal', assets.androidUniversal, null, '', 'androidUniversal', '全架构');
      var androidMeta = document.querySelector('[data-meta="android"]');
      if (androidMeta) {
        if (assets.androidArm64 && assets.androidUniversal) {
          androidMeta.textContent = 'ARM64 精简版 · Universal 全架构兼容';
        } else if (primaryAndroid) {
          var androidSize = formatBytes(primaryAndroid.size);
          androidMeta.textContent = primaryAndroid.name + (androidSize ? ' · ' + androidSize : '');
        } else {
          androidMeta.textContent = '请前往 GitHub Releases 查看';
        }
      }
      bindAsset('macos', assets.macos, 'macos', '请前往 GitHub Releases 查看');
      bindAsset('windows', assets.windows, 'windows', '请前往 GitHub Releases 查看');
      bindAsset('linux', assets.linux, 'linux', '请前往 GitHub Releases 查看');

      var heroAsset = null;
      var platformTitle = '';
      if (detected === 'android') {
        heroAsset = primaryAndroid;
        platformTitle = 'Android';
      } else if (detected === 'macos') {
        heroAsset = assets.macos;
        platformTitle = 'macOS';
      } else if (detected === 'windows') {
        heroAsset = assets.windows;
        platformTitle = 'Windows';
      } else if (detected === 'linux') {
        heroAsset = assets.linux;
        platformTitle = 'Linux';
      }

      if (heroCta && heroCtaLabel && heroCtaMeta) {
        if (detected === 'ios') {
          heroCta.href = '#download';
          heroCtaLabel.textContent = '查看全平台下载 (' + tag + ')';
          heroCtaMeta.textContent = '暂不支持 iOS · 请选用桌面端或 Android 版';
        } else if (heroAsset) {
          heroCta.href = resolveDownloadUrl(heroAsset.browser_download_url, useMirror);
          heroCtaLabel.textContent = '下载 ' + platformTitle + ' 版 (' + tag + ')';
          var heroSize = formatBytes(heroAsset.size);
          heroCtaMeta.textContent = heroAsset.name + (heroSize ? ' · ' + heroSize : '');
        } else {
          heroCta.href = releaseHtmlUrl;
          heroCtaLabel.textContent = '前往 GitHub 下载 (' + tag + ')';
          heroCtaMeta.textContent = '查看所有可用安装包与发布说明';
        }
      }

      renderReleaseNotes(notesBody, currentRelease.body, releaseHtmlUrl);
    }

    updateMirrorButton();
    applyPlatformHighlight();

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
      RELEASES_PAGE: RELEASES_PAGE,
      LATEST_PAGE: LATEST_PAGE,
      MIRROR_PREFIX: MIRROR_PREFIX,
      formatBytes: formatBytes,
      formatDate: formatDate,
      detectPlatform: detectPlatform,
      matchReleaseAssets: matchReleaseAssets,
      resolveDownloadUrl: resolveDownloadUrl
    };
  }
})();
