(function () {
  'use strict';

  var VALID_DRIVERS = ['rule', 'opds', 'ebook_api'];
  var VALID_MODES = ['json', 'html', 'xml'];
  var VALID_TEMPLATE_ROOTS = [
    'origin',
    'query',
    'input',
    'cred',
    'book',
    'step',
    'vars',
    'fields',
    'rand'
  ];

  var SAMPLES = {
    opds: {
      schema_version: 1,
      id: 'example_opds_catalog',
      name: '示例 OPDS 书库',
      description: '连接自建 Calibre / Komga / 标准 OPDS 1.2 或 OPDS 2.0 书库（支持 OpenSearch 自动发现与 Basic 认证）',
      driver: 'opds',
      enabled: true,
      domains: ['https://opds.example.org/opds'],
      probe: {
        path: '',
        timeout_ms: 8000
      },
      auth: {
        required: false,
        modes: [
          {
            id: 'basic',
            label: 'Basic Auth 账号',
            fields: [
              { key: 'username', label: '用户名', type: 'text' },
              { key: 'password', label: '密码', type: 'password' }
            ]
          }
        ]
      },
      opds: {
        prefer_formats: ['epub', 'txt']
      }
    },
    html: {
      schema_version: 1,
      id: 'example_html_two_step',
      name: '示例 HTML 两步提取书源',
      description: '演示 HTML 搜索列表抓取、详情页提取与两步 EPUB 下载链（使用 example.org 占位）',
      driver: 'rule',
      enabled: true,
      domains: ['https://ebooks.example.org'],
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        Accept: 'text/html,application/xhtml+xml,*/*;q=0.8'
      },
      image_headers: {
        Referer: 'https://ebooks.example.org/'
      },
      min_request_interval_ms: 800,
      supported_formats: ['epub'],
      probe: {
        path: '/ebooks',
        timeout_ms: 8000
      },
      auth: {
        required: false
      },
      search: {
        request: {
          method: 'GET',
          path: '/ebooks',
          query: {
            query: '{{query.q}}',
            page: '{{query.page}}'
          },
          page_size: 12
        },
        filters: {
          order: {
            param: 'sort',
            options: [
              { value: '', label: '默认' },
              { value: 'newest', label: '最新' },
              { value: 'author', label: '作者' }
            ]
          }
        },
        response: {
          mode: 'html',
          items_selector: 'ol.book-list > li.book-item',
          pagination: {
            next_page_selector: "nav a[rel='next']"
          },
          fields: {
            ref: { attr: 'data-book-path' },
            title: { selector: 'h3.book-title a' },
            authors: { selector: 'p.book-author span.author', all: true },
            language: { const_value: 'English' },
            format: { const_value: 'epub' },
            cover_url: { selector: 'img.cover', attr: 'src', resolve_url: true },
            source_url: { attr: 'data-book-path', resolve_url: true }
          }
        }
      },
      detail: {
        method: 'GET',
        path: '{{book.ref}}',
        response_mode: 'html',
        fields: {
          description: {
            selector: 'div.book-summary',
            preserve_paragraphs: true
          },
          cover_url: {
            selector: 'img.hero-cover',
            attr: 'src',
            resolve_url: true
          }
        }
      },
      download: {
        steps: [
          {
            id: 'detail_page',
            method: 'GET',
            path: '{{book.ref}}',
            response_mode: 'html',
            extract: {
              url: {
                selectors: [
                  "a.download-epub[href$='.epub']",
                  "a[download][href$='.epub']"
                ],
                attr: 'href',
                resolve_url: true
              }
            }
          }
        ],
        file_request: {
          url: '{{step.detail_page.url}}',
          same_origin_credentials: false,
          headers: {
            Referer: '{{origin}}{{book.ref}}'
          }
        }
      }
    },
    json: {
      schema_version: 1,
      id: 'example_json_api_auth',
      name: '示例 JSON API（含 CSRF 登录与异步轮询）',
      description: '演示 cursor 游标分页、pre_steps CSRF 登录、配额校验与 async poll 下载（使用 example.org 占位）',
      driver: 'rule',
      enabled: true,
      domains: ['https://api.example.org'],
      headers: {
        Accept: 'application/json',
        Origin: 'https://api.example.org',
        Referer: 'https://api.example.org/'
      },
      min_request_interval_ms: 500,
      supported_formats: ['epub'],
      probe: {
        path: '/api/v1/health',
        timeout_ms: 8000
      },
      auth: {
        required: false,
        required_for: ['download'],
        inject: {
          cookies: {
            session_id: '{{cred.session_id}}'
          }
        },
        modes: [
          {
            id: 'password',
            label: '邮箱密码',
            fields: [
              { key: 'email', label: '邮箱', type: 'email' },
              { key: 'password', label: '密码', type: 'password' }
            ],
            login: {
              pre_steps: [
                {
                  id: 'csrf',
                  method: 'GET',
                  path: '/api/v1/auth/csrf',
                  extract: {
                    token: { path: 'data.token' }
                  },
                  extract_cookies: {
                    csrf_cookie: 'csrf_token'
                  }
                }
              ],
              method: 'POST',
              path: '/api/v1/auth/login',
              content_type: 'json',
              headers: {
                'X-CSRF-Token': '{{step.csrf.token}}'
              },
              cookies: {
                csrf_token: '{{step.csrf.csrf_cookie}}'
              },
              body: {
                email: '{{input.email}}',
                password: '{{input.password}}'
              },
              save_credentials: {
                email: { path: 'data.user.email' }
              },
              save_cookie_credentials: {
                session_id: 'session_id'
              }
            }
          },
          {
            id: 'cookies',
            label: 'Cookie 导入',
            fields: [
              {
                key: 'session_id',
                label: 'session_id',
                type: 'password',
                hint: '从浏览器 Cookie 复制 session_id 值'
              }
            ]
          }
        ],
        verify: {
          steps: [
            {
              id: 'quota',
              method: 'GET',
              path: '/api/v1/downloads/quota',
              extract: {
                daily_used: { path: 'data.used' },
                daily_limit: { path: 'data.limit' },
                daily_remaining: { path: 'data.remaining' }
              }
            },
            {
              id: 'profile',
              method: 'GET',
              path: '/api/v1/auth/status',
              extract: {
                email: { path: 'data.user.email' }
              }
            }
          ],
          fields: {
            email: { template: '{{step.profile.email}}' },
            daily_used: { template: '{{step.quota.daily_used}}' },
            daily_limit: { template: '{{step.quota.daily_limit}}' },
            daily_remaining: { template: '{{step.quota.daily_remaining}}' }
          }
        }
      },
      errors: {
        bot_protection: {
          statuses: [403, 503],
          html_body: true
        },
        envelope: {
          error_path: 'error.message',
          error_code_path: 'error.code'
        },
        rules: [
          {
            code: 'QUOTA_EXCEEDED',
            statuses: [429],
            error_code_regex: 'download_daily_limit|quota'
          },
          {
            code: 'SESSION_EXPIRED',
            statuses: [401],
            error_code_regex: 'login_required|unauthorized'
          }
        ]
      },
      search: {
        request: {
          method: 'GET',
          path: '/api/v1/catalog',
          query: {
            q: '{{query.q}}',
            limit: '{{query.limit}}'
          },
          page_size: 20
        },
        response: {
          mode: 'json',
          items_path: 'data.books',
          pagination: {
            total_count_path: 'meta.total',
            page_size: 20,
            cursor_param: 'cursor',
            next_cursor_path: 'meta.nextCursor'
          },
          fields: {
            ref: { path: 'id' },
            title: { path: 'title' },
            authors: { path: 'author', split_regex: '\\s*[,、，;]\\s*' },
            format: { const_value: 'epub' },
            source_url: { template: '{{origin}}/book/{{fields.ref}}' }
          }
        }
      },
      detail: {
        method: 'GET',
        path: '/book/{{book.ref}}',
        headers: {
          Accept: 'text/html,application/xhtml+xml,*/*;q=0.8'
        },
        response_mode: 'html',
        fields: {
          description: {
            selector: "script[type='application/ld+json']",
            json_path: 'description'
          },
          cover_url: {
            selector: "script[type='application/ld+json']",
            json_path: 'image',
            resolve_url: true
          }
        }
      },
      download: {
        steps: [
          {
            id: 'authorize',
            method: 'POST',
            path: '/api/v1/downloads/authorize',
            content_type: 'json',
            body: {
              bookId: '{{book.ref}}',
              requestId: '{{rand.uuid}}'
            },
            extract: {
              state: { path: 'data.state' },
              intent: { path: 'data.intent' },
              url: { path: 'data.url', resolve_url: true }
            },
            poll: {
              method: 'GET',
              path: '/api/v1/downloads/status?intent={{step.authorize.intent}}',
              interval_ms: 3000,
              max_attempts: 40,
              until_path: 'data.state',
              until_value: 'ready',
              fail_path: 'data.state',
              fail_value: 'failed',
              fail_message_path: 'data.message',
              extract: {
                url: { path: 'data.url', resolve_url: true }
              }
            }
          }
        ],
        file_request: {
          url: '{{step.authorize.url}}',
          same_origin_credentials: true,
          headers: {
            Referer: '{{origin}}/book/{{book.ref}}',
            Accept: '*/*'
          }
        }
      }
    }
  };

  function isPlainObject(v) {
    return Boolean(v) && typeof v === 'object' && !Array.isArray(v);
  }

  function asTrimmedString(v) {
    return typeof v === 'string' ? v.trim() : v === undefined || v === null ? '' : String(v).trim();
  }

  function hasNonEmptyStringList(list) {
    if (!Array.isArray(list)) return false;
    for (var i = 0; i < list.length; i++) {
      if (asTrimmedString(list[i])) return true;
    }
    return false;
  }

  function normalizeOriginUrl(raw) {
    var value = asTrimmedString(raw);
    if (!value) return '';
    try {
      var parsed = new URL(value);
      if ((parsed.protocol !== 'http:' && parsed.protocol !== 'https:') || !parsed.host) {
        return '';
      }
      while (value.charAt(value.length - 1) === '/') {
        value = value.slice(0, -1);
      }
      return value;
    } catch (_) {
      return '';
    }
  }

  function isExtractRuleConfigured(raw) {
    if (typeof raw === 'string') {
      return raw.trim().length > 0;
    }
    if (!isPlainObject(raw)) return false;
    if (
      asTrimmedString(raw.selector) ||
      hasNonEmptyStringList(raw.selectors) ||
      asTrimmedString(raw.attr) ||
      hasNonEmptyStringList(raw.attrs) ||
      asTrimmedString(raw.path) ||
      hasNonEmptyStringList(raw.paths) ||
      hasNonEmptyStringList(raw.path_segments) ||
      asTrimmedString(raw.json_path) ||
      asTrimmedString(raw.cookie) ||
      (typeof raw.template === 'string' && raw.template.length > 0) ||
      (typeof raw.const_value === 'string' && raw.const_value.length > 0)
    ) {
      return true;
    }
    if (Array.isArray(raw.first_of) && raw.first_of.length > 0) {
      return true;
    }
    if (raw.when_present !== undefined && raw.when_present !== null) {
      return true;
    }
    return false;
  }

  function collectCredentialKeys(authObj) {
    var keys = [];
    if (!isPlainObject(authObj) || !Array.isArray(authObj.modes)) return keys;
    for (var i = 0; i < authObj.modes.length; i++) {
      var mode = authObj.modes[i];
      if (!isPlainObject(mode)) continue;
      if (isPlainObject(mode.login)) {
        if (isPlainObject(mode.login.save_credentials)) {
          var scKeys = Object.keys(mode.login.save_credentials);
          for (var a = 0; a < scKeys.length; a++) {
            if (keys.indexOf(scKeys[a]) === -1) keys.push(scKeys[a]);
          }
        }
        if (isPlainObject(mode.login.save_cookie_credentials)) {
          var ckKeys = Object.keys(mode.login.save_cookie_credentials);
          for (var b = 0; b < ckKeys.length; b++) {
            if (keys.indexOf(ckKeys[b]) === -1) keys.push(ckKeys[b]);
          }
        }
      } else if (Array.isArray(mode.fields)) {
        for (var f = 0; f < mode.fields.length; f++) {
          var field = mode.fields[f];
          if (isPlainObject(field)) {
            var k = asTrimmedString(field.key);
            if (k && keys.indexOf(k) === -1) keys.push(k);
          }
        }
      }
    }
    return keys;
  }

  function hasUnsafeScheme(urlValue) {
    if (typeof urlValue !== 'string') return false;
    var trimmed = urlValue.trim().toLowerCase();
    return trimmed.indexOf('javascript:') === 0 || trimmed.indexOf('data:') === 0;
  }

  function auditSource(src, errors, warnings) {
    var srcId = asTrimmedString(src.id) || '(unknown)';
    var definedVars = {};

    if (isPlainObject(src.search) && isPlainObject(src.search.response) && isPlainObject(src.search.response.vars)) {
      var svKeys = Object.keys(src.search.response.vars);
      for (var i = 0; i < svKeys.length; i++) {
        definedVars[svKeys[i]] = true;
      }
    }
    if (isPlainObject(src.detail) && isPlainObject(src.detail.vars)) {
      var dvKeys = Object.keys(src.detail.vars);
      for (var j = 0; j < dvKeys.length; j++) {
        definedVars[dvKeys[j]] = true;
      }
    }

    var credKeys = collectCredentialKeys(src.auth);

    function checkRegex(pattern, where) {
      if (typeof pattern !== 'string' || pattern === '') return;
      if (/\(\?(?![:=!<])/.test(pattern)) {
        errors.push(
          '[' + srcId + '] ' + where + ' 包含 Dart RegExp 不支持的内联修饰符（如 (?i)），请移除并依赖引擎参数'
        );
        return;
      }
      try {
        new RegExp(pattern);
      } catch (e) {
        errors.push('[' + srcId + '] ' + where + ' 正则表达式无效 "' + pattern + '": ' + e.message);
      }
    }

    function checkTemplatesInText(text, where, availableStepIds) {
      if (typeof text !== 'string' || text.indexOf('{{') === -1) return;
      var re = /\{\{([a-zA-Z0-9_.-]+)\}\}/g;
      var m;
      while ((m = re.exec(text)) !== null) {
        var expr = m[1];
        var parts = expr.split('.');
        var root = parts[0];
        if (VALID_TEMPLATE_ROOTS.indexOf(root) === -1) {
          warnings.push('[' + srcId + '] ' + where + ' 含未识别模板变量 {{' + expr + '}}');
          continue;
        }
        if (root === 'book' && parts.length >= 3 && parts[1] === 'var') {
          var varName = parts.slice(2).join('.');
          if (!definedVars[varName]) {
            warnings.push('[' + srcId + '] ' + where + ' 引用了未在 vars 中声明的 {{' + expr + '}}');
          }
        } else if (root === 'step' && parts.length >= 2) {
          var stepId = parts[1];
          if (stepId !== 'last' && (!availableStepIds || !availableStepIds[stepId])) {
            warnings.push('[' + srcId + '] ' + where + ' 引用了未定义或顺序靠后的步骤 "{{' + expr + '}}"');
          }
        } else if (
          root === 'cred' &&
          parts.length >= 2 &&
          credKeys.length > 0 &&
          credKeys.indexOf(parts[1]) === -1
        ) {
          warnings.push(
            '[' + srcId + '] ' + where + ' 引用了 {{' + expr + '}}，但 auth.modes 中未声明凭据键 ' + parts[1]
          );
        }
      }
    }

    function checkTemplateDynamic(raw, where, availableStepIds) {
      if (typeof raw === 'string') {
        checkTemplatesInText(raw, where, availableStepIds);
      } else if (Array.isArray(raw)) {
        for (var i = 0; i < raw.length; i++) {
          checkTemplateDynamic(raw[i], where, availableStepIds);
        }
      } else if (isPlainObject(raw)) {
        var keys = Object.keys(raw);
        for (var j = 0; j < keys.length; j++) {
          checkTemplateDynamic(raw[keys[j]], where + '.' + keys[j], availableStepIds);
        }
      }
    }

    function checkExtractRule(rule, where, availableStepIds) {
      if (!isPlainObject(rule)) return;
      checkRegex(rule.regex, where + '.regex');
      checkRegex(rule.replace_pattern, where + '.replace_pattern');
      checkRegex(rule.split_regex, where + '.split_regex');
      if (typeof rule.template === 'string' && rule.template.length > 0) {
        checkTemplatesInText(rule.template, where + '.template', availableStepIds);
      }
      if (Array.isArray(rule.first_of)) {
        for (var i = 0; i < rule.first_of.length; i++) {
          checkExtractRule(rule.first_of[i], where + '.first_of[' + i + ']', availableStepIds);
        }
      }
      if (rule.when_present !== undefined && rule.when_present !== null) {
        checkExtractRule(rule.when_present, where + '.when_present', availableStepIds);
      }
    }

    function checkExtractMap(mapObj, where, availableStepIds) {
      if (!isPlainObject(mapObj)) return;
      var keys = Object.keys(mapObj);
      for (var i = 0; i < keys.length; i++) {
        checkExtractRule(mapObj[keys[i]], where + '.' + keys[i], availableStepIds);
      }
    }

    function checkStaticSecretHeaders(headersObj, where) {
      if (!isPlainObject(headersObj)) return;
      var keys = Object.keys(headersObj);
      for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        var kLower = k.toLowerCase();
        var val = asTrimmedString(headersObj[k]);
        if ((kLower === 'cookie' || kLower === 'authorization') && val && val.indexOf('{{') === -1) {
          warnings.push('[' + srcId + '] ' + where + '.' + k + ' 含硬编码敏感头，发布前请改为 {{cred.*}} 模板');
        }
      }
    }

    checkStaticSecretHeaders(src.headers, 'headers');
    checkStaticSecretHeaders(src.image_headers, 'image_headers');

    if (isPlainObject(src.auth)) {
      var auth = src.auth;
      if (isPlainObject(auth.inject)) {
        checkTemplateDynamic(auth.inject.headers, 'auth.inject.headers');
        checkTemplateDynamic(auth.inject.cookies, 'auth.inject.cookies');
        checkTemplateDynamic(auth.inject.query, 'auth.inject.query');
      }
      if (Array.isArray(auth.modes)) {
        for (var mIdx = 0; mIdx < auth.modes.length; mIdx++) {
          var mode = auth.modes[mIdx];
          if (!isPlainObject(mode) || !isPlainObject(mode.login)) continue;
          var login = mode.login;
          var modeId = asTrimmedString(mode.id) || String(mIdx);
          var seenPreIds = {};
          if (Array.isArray(login.pre_steps)) {
            for (var pIdx = 0; pIdx < login.pre_steps.length; pIdx++) {
              var pre = login.pre_steps[pIdx];
              if (!isPlainObject(pre)) continue;
              var pw = 'auth.modes(' + modeId + ').login.pre_steps[' + pIdx + ']';
              checkTemplateDynamic(pre.path, pw + '.path', seenPreIds);
              checkTemplateDynamic(pre.url, pw + '.url', seenPreIds);
              checkTemplateDynamic(pre.headers, pw + '.headers', seenPreIds);
              checkTemplateDynamic(pre.cookies, pw + '.cookies', seenPreIds);
              checkTemplateDynamic(pre.body, pw + '.body', seenPreIds);
              checkRegex(pre.follow_while_url_regex, pw + '.follow_while_url_regex');
              checkExtractMap(pre.extract, pw + '.extract', seenPreIds);
              var preId = asTrimmedString(pre.id);
              if (preId) seenPreIds[preId] = true;
            }
          }
          checkTemplateDynamic(login.path, 'auth.modes(' + modeId + ').login.path', seenPreIds);
          checkTemplateDynamic(login.headers, 'auth.modes(' + modeId + ').login.headers', seenPreIds);
          checkTemplateDynamic(login.cookies, 'auth.modes(' + modeId + ').login.cookies', seenPreIds);
          checkTemplateDynamic(login.body, 'auth.modes(' + modeId + ').login.body', seenPreIds);
          checkExtractMap(login.save_credentials, 'auth.modes(' + modeId + ').login.save_credentials', seenPreIds);
        }
      }
      if (isPlainObject(auth.verify)) {
        var verify = auth.verify;
        var seenVerifyIds = {};
        if (Array.isArray(verify.steps)) {
          for (var vIdx = 0; vIdx < verify.steps.length; vIdx++) {
            var vst = verify.steps[vIdx];
            if (!isPlainObject(vst)) continue;
            var vw = 'auth.verify.steps[' + vIdx + ']';
            checkTemplateDynamic(vst.path, vw + '.path', seenVerifyIds);
            checkTemplateDynamic(vst.url, vw + '.url', seenVerifyIds);
            checkTemplateDynamic(vst.headers, vw + '.headers', seenVerifyIds);
            checkExtractMap(vst.extract, vw + '.extract', seenVerifyIds);
            var vid = asTrimmedString(vst.id);
            if (vid) seenVerifyIds[vid] = true;
          }
        }
        checkTemplateDynamic(verify.headers, 'auth.verify.headers', seenVerifyIds);
        checkExtractMap(verify.fields, 'auth.verify.fields', seenVerifyIds);
      }
    }

    if (isPlainObject(src.errors) && Array.isArray(src.errors.rules)) {
      for (var eIdx = 0; eIdx < src.errors.rules.length; eIdx++) {
        var er = src.errors.rules[eIdx];
        if (!isPlainObject(er)) continue;
        checkRegex(er.error_code_regex, 'errors.rules[' + eIdx + '].error_code_regex');
        checkRegex(er.error_regex, 'errors.rules[' + eIdx + '].error_regex');
      }
    }

    if (isPlainObject(src.search)) {
      var search = src.search;
      if (isPlainObject(search.request)) {
        checkTemplateDynamic(search.request.path, 'search.request.path');
        checkTemplateDynamic(search.request.url, 'search.request.url');
        checkTemplateDynamic(search.request.headers, 'search.request.headers');
        checkTemplateDynamic(search.request.query, 'search.request.query');
        checkTemplateDynamic(search.request.body, 'search.request.body');
      }
      if (isPlainObject(search.response)) {
        checkExtractMap(search.response.vars, 'search.response.vars');
        checkExtractMap(search.response.fields, 'search.response.fields');
        var rMode = asTrimmedString(search.response.mode || 'json').toLowerCase();
        var intervalMs = typeof src.min_request_interval_ms === 'number' ? src.min_request_interval_ms : 0;
        if (rMode === 'html' && intervalMs === 0) {
          warnings.push('[' + srcId + '] HTML 抓取建议设置 min_request_interval_ms >= 500 以避免触发风控');
        }
      }
    }

    if (isPlainObject(src.detail)) {
      checkTemplateDynamic(src.detail.path, 'detail.path');
      checkTemplateDynamic(src.detail.url, 'detail.url');
      checkTemplateDynamic(src.detail.headers, 'detail.headers');
      checkExtractMap(src.detail.vars, 'detail.vars');
      checkExtractMap(src.detail.fields, 'detail.fields');
    }

    if (isPlainObject(src.download)) {
      var dl = src.download;
      var seenStepIds = {};
      if (Array.isArray(dl.steps)) {
        for (var sIdx = 0; sIdx < dl.steps.length; sIdx++) {
          var st = dl.steps[sIdx];
          if (!isPlainObject(st)) continue;
          var sw = 'download.steps[' + sIdx + ']';
          checkTemplateDynamic(st.path, sw + '.path', seenStepIds);
          checkTemplateDynamic(st.url, sw + '.url', seenStepIds);
          checkTemplateDynamic(st.headers, sw + '.headers', seenStepIds);
          checkTemplateDynamic(st.cookies, sw + '.cookies', seenStepIds);
          checkTemplateDynamic(st.query, sw + '.query', seenStepIds);
          checkTemplateDynamic(st.body, sw + '.body', seenStepIds);
          checkRegex(st.follow_while_url_regex, sw + '.follow_while_url_regex');
          checkExtractMap(st.extract, sw + '.extract', seenStepIds);
          var stepId = asTrimmedString(st.id);
          if (stepId) seenStepIds[stepId] = true;
          if (isPlainObject(st.poll)) {
            checkTemplateDynamic(st.poll.path, sw + '.poll.path', seenStepIds);
            checkTemplateDynamic(st.poll.url, sw + '.poll.url', seenStepIds);
            checkExtractMap(st.poll.extract, sw + '.poll.extract', seenStepIds);
          }
        }
      }
      if (isPlainObject(dl.file_request)) {
        if (hasUnsafeScheme(dl.file_request.url) || hasUnsafeScheme(dl.file_request.path)) {
          errors.push('[' + srcId + '] download.file_request 禁止使用 javascript: 或 data: 危险协议');
        }
        checkTemplateDynamic(dl.file_request.url, 'download.file_request.url', seenStepIds);
        checkTemplateDynamic(dl.file_request.path, 'download.file_request.path', seenStepIds);
        checkTemplateDynamic(dl.file_request.headers, 'download.file_request.headers', seenStepIds);
      }
    }
  }

  function validateBookSourceJson(rawText) {
    var errors = [];
    var warnings = [];
    var checks = [];
    var parsedSources = [];

    if (typeof rawText !== 'string' || rawText.trim() === '') {
      return {
        ok: false,
        strictOk: false,
        bundleMeta: null,
        sources: [],
        errors: ['请先粘贴或载入 JSON 配置内容'],
        warnings: [],
        checks: []
      };
    }

    var decoded;
    try {
      decoded = JSON.parse(rawText);
    } catch (e) {
      return {
        ok: false,
        strictOk: false,
        bundleMeta: null,
        sources: [],
        errors: ['JSON 语法无效：' + e.message],
        warnings: [],
        checks: []
      };
    }

    if (!isPlainObject(decoded)) {
      return {
        ok: false,
        strictOk: false,
        bundleMeta: null,
        sources: [],
        errors: ['JSON 根节点必须是对象（{ ... }）'],
        warnings: [],
        checks: []
      };
    }

    var isBundle = Array.isArray(decoded.sources);
    var bundleSchema =
      typeof decoded.schema_version === 'number'
        ? Math.trunc(decoded.schema_version)
        : isBundle
          ? 0
          : 1;

    var bundleMeta = {
      isBundle: isBundle,
      schemaVersion: bundleSchema,
      configVersion: asTrimmedString(decoded.config_version),
      name: asTrimmedString(decoded.name)
    };

    if (bundleSchema !== 1) {
      errors.push('不支持的书源 schema_version：' + bundleSchema + '（当前仅支持 1）');
    }

    var rawSources = isBundle ? decoded.sources : [decoded];
    if (rawSources.length === 0) {
      errors.push('书源配置中至少需要包含 1 条书源');
    }

    var seenIds = {};
    for (var i = 0; i < rawSources.length; i++) {
      var rawSrc = rawSources[i];
      if (!isPlainObject(rawSrc)) {
        errors.push('sources[' + i + '] 必须是对象');
        continue;
      }

      var srcSchema =
        typeof rawSrc.schema_version === 'number'
          ? Math.trunc(rawSrc.schema_version)
          : bundleSchema > 0
            ? bundleSchema
            : 1;
      var srcId = asTrimmedString(rawSrc.id);
      var srcName = asTrimmedString(rawSrc.name);
      var rawDriverPresent = rawSrc.driver !== undefined && rawSrc.driver !== null;
      var driver = rawDriverPresent ? asTrimmedString(rawSrc.driver).toLowerCase() : 'rule';
      var defaultEnabled = rawSrc.enabled !== undefined ? Boolean(rawSrc.enabled) : true;

      if (srcSchema !== 1) {
        errors.push('[' + (srcId || 'sources[' + i + ']') + '] 不支持的书源 schema_version：' + srcSchema);
      }
      if (!srcId) {
        errors.push('sources[' + i + '] 缺少必填字段 id');
      } else {
        if (!/^[a-zA-Z0-9_-]{1,64}$/.test(srcId)) {
          errors.push('书源 id "' + srcId + '" 仅允许字母、数字、下划线或连字符（最长 64 字符）');
        }
        if (seenIds[srcId]) {
          errors.push('存在重复的书源 id：' + srcId);
        }
        seenIds[srcId] = true;
      }

      if (!srcName) {
        errors.push('书源 ' + (srcId || 'sources[' + i + ']') + ' 缺少 name');
      }

      if (rawDriverPresent && VALID_DRIVERS.indexOf(driver) === -1) {
        errors.push(
          '书源 ' +
            (srcId || 'sources[' + i + ']') +
            ' 的 driver "' +
            rawSrc.driver +
            '" 不受支持（仅支持 rule / opds / ebook_api）'
        );
      }

      var rawDomainCandidates = [];
      if (Array.isArray(rawSrc.domains)) {
        for (var dIdx = 0; dIdx < rawSrc.domains.length; dIdx++) {
          var cand = asTrimmedString(rawSrc.domains[dIdx]);
          if (cand) rawDomainCandidates.push(cand);
        }
      }
      var baseUrl = asTrimmedString(rawSrc.base_url);
      if (baseUrl) rawDomainCandidates.push(baseUrl);

      var validDomains = [];
      for (var cIdx = 0; cIdx < rawDomainCandidates.length; cIdx++) {
        var rawDomain = rawDomainCandidates[cIdx];
        var norm = normalizeOriginUrl(rawDomain);
        if (!norm) {
          errors.push('书源 ' + (srcId || 'sources[' + i + ']') + ' 包含非法域名：' + rawDomain);
        } else if (validDomains.indexOf(norm) === -1) {
          validDomains.push(norm);
        }
      }
      if (validDomains.length === 0) {
        errors.push('书源 ' + (srcId || 'sources[' + i + ']') + ' 至少需要 1 个合法的 http(s) 域名（domains / base_url）');
      }

      if (driver === 'rule') {
        if (!isPlainObject(rawSrc.search)) {
          errors.push('rule 书源 ' + (srcId || 'sources[' + i + ']') + ' 缺少 search 配置');
        } else {
          var req = rawSrc.search.request;
          if (!isPlainObject(req) || (!asTrimmedString(req.path) && !asTrimmedString(req.url))) {
            errors.push('rule 书源 ' + (srcId || 'sources[' + i + ']') + ' 的 search.request 缺少 path 或 url');
          } else if (hasUnsafeScheme(req.url) || hasUnsafeScheme(req.path)) {
            errors.push('rule 书源 ' + (srcId || 'sources[' + i + ']') + ' 的 search.request 禁止使用危险协议');
          }

          var resp = rawSrc.search.response;
          if (!isPlainObject(resp)) {
            errors.push('rule 书源 ' + (srcId || 'sources[' + i + ']') + ' 缺少 search.response 配置');
          } else {
            var mode = asTrimmedString(resp.mode || 'json').toLowerCase();
            if (VALID_MODES.indexOf(mode) === -1) {
              errors.push('rule 书源 ' + (srcId || 'sources[' + i + ']') + ' 的 search.response.mode 仅支持 json / html / xml');
            }
            if (mode === 'html' && !asTrimmedString(resp.items_selector)) {
              errors.push('HTML 书源 ' + (srcId || 'sources[' + i + ']') + ' 缺少 search.response.items_selector');
            }
            var fields = resp.fields;
            if (!isPlainObject(fields) || !isExtractRuleConfigured(fields.title)) {
              errors.push('rule 书源 ' + (srcId || 'sources[' + i + ']') + ' 的 search.response.fields 缺少 title');
            }
            if (!isPlainObject(fields) || !isExtractRuleConfigured(fields.ref)) {
              errors.push('rule 书源 ' + (srcId || 'sources[' + i + ']') + ' 的 search.response.fields 缺少 ref');
            }
          }
        }

        if (
          !isPlainObject(rawSrc.download) ||
          !isPlainObject(rawSrc.download.file_request) ||
          (!asTrimmedString(rawSrc.download.file_request.url) &&
            !asTrimmedString(rawSrc.download.file_request.path))
        ) {
          errors.push('rule 书源 ' + (srcId || 'sources[' + i + ']') + ' 缺少 download.file_request（url 或 path）');
        }
      }

      parsedSources.push({
        id: srcId || 'sources[' + i + ']',
        name: srcName || '(未命名)',
        driver: driver,
        domainCount: validDomains.length,
        defaultEnabled: defaultEnabled
      });

      auditSource(rawSrc, errors, warnings);
    }

    if (errors.length === 0) {
      checks.push('Schema v1 必填结构与驱动约束校验通过');
      checks.push('所有域名均使用合法 http(s) 协议，无 javascript:/data: 危险 URL');
      checks.push('全部正则表达式兼容 Dart RegExp（无 (?i) 等内联修饰符）');
    }
    if (warnings.length === 0 && errors.length === 0) {
      checks.push('模板变量、步骤依赖及 Cookie/Authorization 脱敏检查均零警告');
    }

    return {
      ok: errors.length === 0,
      strictOk: errors.length === 0 && warnings.length === 0,
      bundleMeta: bundleMeta,
      sources: parsedSources,
      errors: errors,
      warnings: warnings,
      checks: checks
    };
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
    var groups = [];

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

        groups.push({ tabs: tabs, activate: activateTab });

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

    var triggers = document.querySelectorAll('[data-select-tab]');
    for (var r = 0; r < triggers.length; r++) {
      (function (trigger) {
        trigger.addEventListener('click', function () {
          var targetId = trigger.getAttribute('data-select-tab');
          var targetTab = targetId ? document.getElementById(targetId) : null;
          if (!targetTab) return;
          for (var g = 0; g < groups.length; g++) {
            if (groups[g].tabs.indexOf(targetTab) !== -1) {
              groups[g].activate(targetTab, false);
              break;
            }
          }
        });
      })(triggers[r]);
    }
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
    var buttons = document.querySelectorAll('.copy-btn:not([data-load-sample])');
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

  function renderValidationReport(reportEl, result) {
    if (!reportEl) return;
    while (reportEl.firstChild) {
      reportEl.removeChild(reportEl.firstChild);
    }

    var statusEl = document.createElement('div');
    statusEl.className = 'validator-status';
    if (!result) {
      statusEl.classList.add('is-idle');
      statusEl.textContent = '输入或载入书源 JSON 后点击「立即校验配置」';
      reportEl.appendChild(statusEl);
      return;
    }

    if (!result.ok) {
      statusEl.classList.add('is-error');
      statusEl.textContent =
        '校验未通过：发现 ' +
        result.errors.length +
        ' 处错误' +
        (result.warnings.length ? '、' + result.warnings.length + ' 条警告' : '');
    } else if (result.warnings.length > 0) {
      statusEl.classList.add('is-warn');
      statusEl.textContent =
        '基础 Schema 通过，但存在 ' + result.warnings.length + ' 条警告（--strict 模式将视为未通过）';
    } else {
      statusEl.classList.add('is-ok');
      statusEl.textContent =
        'OK · 严格校验通过（已解析 ' + result.sources.length + ' 条书源，0 错误 0 警告）';
    }
    reportEl.appendChild(statusEl);

    if (result.sources.length > 0) {
      var summaryWrap = document.createElement('div');
      summaryWrap.className = 'validator-summary-list';
      for (var s = 0; s < result.sources.length; s++) {
        var src = result.sources[s];
        var pill = document.createElement('span');
        pill.className = 'validator-source-pill';
        pill.textContent =
          src.id + ' [' + src.driver + '] · ' + src.name + ' (' + src.domainCount + ' 域名)';
        summaryWrap.appendChild(pill);
      }
      reportEl.appendChild(summaryWrap);
    }

    var listEl = document.createElement('ul');
    listEl.className = 'validator-issues';

    for (var i = 0; i < result.errors.length; i++) {
      var errLi = document.createElement('li');
      errLi.className = 'issue-error';
      errLi.textContent = 'ERROR: ' + result.errors[i];
      listEl.appendChild(errLi);
    }
    for (var w = 0; w < result.warnings.length; w++) {
      var warnLi = document.createElement('li');
      warnLi.className = 'issue-warning';
      warnLi.textContent = 'WARNING: ' + result.warnings[w];
      listEl.appendChild(warnLi);
    }
    for (var c = 0; c < result.checks.length; c++) {
      var okLi = document.createElement('li');
      okLi.className = 'issue-pass';
      okLi.textContent = 'PASS: ' + result.checks[c];
      listEl.appendChild(okLi);
    }

    reportEl.appendChild(listEl);
  }

  function initValidator() {
    var inputEl = document.getElementById('validator-input');
    var reportEl = document.getElementById('validator-report');
    var runBtn = document.getElementById('validator-run-btn');
    var formatBtn = document.getElementById('validator-format-btn');
    var clearBtn = document.getElementById('validator-clear-btn');
    var validatorSection = document.getElementById('validator');

    if (!inputEl || !reportEl) return;

    function runNow() {
      var res = validateBookSourceJson(inputEl.value);
      renderValidationReport(reportEl, res);
    }

    function loadSample(key, shouldScroll) {
      var sample = SAMPLES[key];
      if (!sample) return;
      inputEl.value = JSON.stringify(sample, null, 2);
      runNow();
      if (shouldScroll && validatorSection && typeof validatorSection.scrollIntoView === 'function') {
        validatorSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    }

    var sampleButtons = document.querySelectorAll('[data-load-sample]');
    for (var i = 0; i < sampleButtons.length; i++) {
      (function (btn) {
        btn.addEventListener('click', function () {
          var key = btn.getAttribute('data-load-sample');
          var insideEditor = Boolean(btn.closest('.validator-editor'));
          loadSample(key, !insideEditor);
        });
      })(sampleButtons[i]);
    }

    if (runBtn) {
      runBtn.addEventListener('click', runNow);
    }

    if (formatBtn) {
      formatBtn.addEventListener('click', function () {
        try {
          var parsed = JSON.parse(inputEl.value);
          inputEl.value = JSON.stringify(parsed, null, 2);
          runNow();
        } catch (e) {
          renderValidationReport(reportEl, {
            ok: false,
            strictOk: false,
            bundleMeta: null,
            sources: [],
            errors: ['JSON 语法有误，无法格式化：' + e.message],
            warnings: [],
            checks: []
          });
        }
      });
    }

    if (clearBtn) {
      clearBtn.addEventListener('click', function () {
        inputEl.value = '';
        renderValidationReport(reportEl, null);
      });
    }

    if (!inputEl.value.trim()) {
      loadSample('opds', false);
    } else {
      runNow();
    }
  }

  function bootBrowser() {
    initThemeToggle();
    initTabLists();
    initCopyButtons();
    initValidator();
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
      SAMPLES: SAMPLES,
      VALID_DRIVERS: VALID_DRIVERS,
      VALID_TEMPLATE_ROOTS: VALID_TEMPLATE_ROOTS,
      normalizeOriginUrl: normalizeOriginUrl,
      validateBookSourceJson: validateBookSourceJson
    };
  }
})();
